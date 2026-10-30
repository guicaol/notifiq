defmodule Notifiq.Test.FakeProvider do
  @moduledoc """
  Fake SMS-only provider for tests. Its behaviour is driven by `message.metadata`:

    * `:notify`   — pid that receives `{:provider_called, message, credentials}`
    * `:scenario` — `:ok` (default) | `:retryable` | `:permanent` | `:uncertain` |
      `:raise` | `:sleep` | `:bad_return` | `:bad_reason`

  A body starting with `"[scenario:NAME]"` selects the scenario too, for messages built
  from a stored `message_log` (which keeps no metadata).
  """

  @behaviour Notifiq.Channels.Provider

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt

  @impl true
  def provider_key, do: :fake_sms

  @impl true
  def supported_channels, do: [:sms]

  @impl true
  def send_message(%OutboundMessage{metadata: metadata} = message, credentials) do
    if pid = metadata[:notify], do: send(pid, {:provider_called, message, credentials})

    case metadata[:scenario] || scenario_from_body(message.body) do
      :ok ->
        {:ok,
         %SendReceipt{
           provider: Atom.to_string(provider_key()),
           provider_message_id: "fake-" <> message.idempotency_key,
           status: :queued,
           raw: %{"sid" => "fake-" <> message.idempotency_key}
         }}

      :retryable ->
        {:error, {:retryable, :rate_limited}}

      :permanent ->
        {:error, {:permanent, :invalid_number}}

      :uncertain ->
        {:error, {:uncertain, :connection_reset}}

      # The exception text embeds the recipient and body on purpose: the dispatcher
      # must never copy it to the logs.
      :raise ->
        raise "boom sending #{message.body} to #{message.to}"

      :sleep ->
        Process.sleep(5_000)

      :bad_return ->
        :definitely_not_a_valid_result

      :bad_reason ->
        {:error, {:retryable, "free text from the provider"}}
    end
  end

  @scenarios %{
    "ok" => :ok,
    "retryable" => :retryable,
    "permanent" => :permanent,
    "uncertain" => :uncertain
  }

  defp scenario_from_body("[scenario:" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [name, _body] -> Map.get(@scenarios, name, :ok)
      _no_closing_bracket -> :ok
    end
  end

  defp scenario_from_body(_body), do: :ok
end
