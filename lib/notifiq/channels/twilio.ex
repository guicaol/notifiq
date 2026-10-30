defmodule Notifiq.Channels.Twilio do
  @moduledoc """
  `Notifiq.Channels.Provider` for Twilio SMS (Spec 005).

  Sends through the Messages API
  (`POST /2010-04-01/Accounts/{AccountSid}/Messages.json`, form encoded, HTTP Basic)
  and classifies every outcome as `:retryable`, `:permanent` or `:uncertain`.

  ## Credentials

  A map with atom keys, built in `config/runtime.exs` from the environment:

    * `:account_sid` — required (it is part of the URL)
    * `:auth_token` — or `:api_key_sid` + `:api_key_secret`, which take precedence
    * `:messaging_service_sid` or `:sms_from` — the sender; the service prevails

  ## Decisions worth knowing

    * WhatsApp is not supported: business-initiated WhatsApp messages need an approved
      template (`ContentSid`), which `OutboundMessage` can't carry yet.
    * No automatic retry (`retry: false`): a re-posted request may duplicate the SMS.
    * No idempotency header: the docs don't state the Messages API honours one.
    * 5xx is `:uncertain`, not `:retryable`: the docs don't say whether the message was
      processed. Only 429 is documented as "not processed, safe to retry".
    * Logs carry the HTTP status and Twilio `code` only — never the recipient, body,
      credentials or Twilio's error text (it can echo the phone number).
  """

  @behaviour Notifiq.Channels.Provider

  require Logger

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt

  @default_req_options [
    base_url: "https://api.twilio.com",
    receive_timeout: 8_000,
    connect_options: [timeout: 3_000],
    retry: false,
    # We decode ourselves: a gateway's HTML error page must be classified by its status,
    # not crash the request with a decode error.
    decode_body: false
  ]

  # Never `to`, `from` or `body`: the raw receipt is stored for audit.
  @receipt_fields ~w(sid status num_segments date_created messaging_service_sid error_code error_message)

  @queued_statuses ~w(queued accepted scheduled)
  @sent_statuses ~w(sending sent)
  @failed_statuses ~w(failed undelivered canceled)

  @code_reasons %{
    21_211 => :invalid_number,
    21_614 => :not_a_mobile_number,
    21_610 => :recipient_unsubscribed,
    21_408 => :region_not_permitted,
    21_608 => :account_unverified
  }

  @impl true
  def provider_key, do: :twilio

  @impl true
  def supported_channels, do: [:sms]

  @impl true
  def send_message(%OutboundMessage{} = message, credentials) do
    with {:ok, config} <- fetch_config(credentials) do
      message
      |> post(config)
      |> classify()
    end
  end

  defp fetch_config(credentials) do
    account_sid = present(Map.get(credentials, :account_sid))

    basic_auth =
      case {present(Map.get(credentials, :api_key_sid)),
            present(Map.get(credentials, :api_key_secret))} do
        {key_sid, secret} when is_binary(key_sid) and is_binary(secret) -> {key_sid, secret}
        _no_api_key -> {account_sid, present(Map.get(credentials, :auth_token))}
      end

    sender =
      case {present(Map.get(credentials, :messaging_service_sid)),
            present(Map.get(credentials, :sms_from))} do
        {service, _from} when is_binary(service) -> {"MessagingServiceSid", service}
        {nil, from} when is_binary(from) -> {"From", from}
        _no_sender -> nil
      end

    case {account_sid, basic_auth, sender} do
      {sid, {user, password}, {_param, _value} = sender}
      when is_binary(sid) and is_binary(user) and is_binary(password) ->
        {:ok, %{account_sid: sid, user: user, password: password, sender: sender}}

      _incomplete ->
        {:error, {:permanent, :missing_credentials}}
    end
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_other), do: nil

  defp post(message, %{sender: {sender_param, sender_value}} = config) do
    Req.post(client(),
      url: "/2010-04-01/Accounts/#{config.account_sid}/Messages.json",
      auth: {:basic, "#{config.user}:#{config.password}"},
      form: %{"To" => message.to, "Body" => message.body, sender_param => sender_value}
    )
  end

  defp client do
    configured =
      :notifiq |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    @default_req_options |> Keyword.merge(configured) |> Req.new()
  end

  defp classify({:ok, %Req.Response{status: status, body: raw}}) when status in 200..299 do
    receipt(decode(raw))
  end

  defp classify({:ok, %Req.Response{status: status, body: raw}}) do
    twilio_code = raw |> decode() |> code()
    error = error_for(status, twilio_code)
    Logger.warning("twilio request failed status=#{status} code=#{twilio_code || "none"}")
    {:error, error}
  end

  defp classify({:error, exception}) do
    error = transport_error(exception)
    Logger.warning("twilio request failed transport_error=#{transport_reason(exception)}")
    {:error, error}
  end

  defp receipt(%{"sid" => sid, "status" => status} = body) when is_binary(sid) do
    cond do
      status in @queued_statuses -> {:ok, build_receipt(sid, :queued, body)}
      status in @sent_statuses -> {:ok, build_receipt(sid, :sent, body)}
      status in @failed_statuses -> {:error, {:permanent, :rejected}}
      true -> {:error, {:uncertain, :invalid_response}}
    end
  end

  defp receipt(_body), do: {:error, {:uncertain, :invalid_response}}

  defp build_receipt(sid, status, body) do
    %SendReceipt{
      provider: Atom.to_string(provider_key()),
      provider_message_id: sid,
      status: status,
      raw: Map.take(body, @receipt_fields)
    }
  end

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> body
      _not_a_json_object -> %{}
    end
  end

  defp decode(_raw), do: %{}

  defp code(%{"code" => code}) when is_integer(code), do: code
  defp code(_body), do: nil

  defp error_for(429, _code), do: {:retryable, :rate_limited}
  defp error_for(_status, 20_429), do: {:retryable, :rate_limited}
  defp error_for(401, _code), do: {:permanent, :invalid_credentials}
  defp error_for(403, _code), do: {:permanent, :forbidden}
  defp error_for(status, _code) when status >= 500, do: {:uncertain, :provider_unavailable}

  defp error_for(status, code) when status in 400..499,
    do: {:permanent, Map.get(@code_reasons, code, :rejected)}

  defp error_for(_status, _code), do: {:uncertain, :invalid_response}

  # Only failures that happen before any bytes could reach Twilio are safe to retry.
  defp transport_error(%{reason: reason}) when reason in [:econnrefused, :nxdomain],
    do: {:retryable, :connection_failed}

  defp transport_error(%{reason: :timeout}), do: {:uncertain, :timeout}
  defp transport_error(_exception), do: {:uncertain, :connection_lost}

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_exception), do: :unknown
end
