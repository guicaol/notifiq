defmodule Notifiq.Channels.OutboundMessage do
  @moduledoc """
  A message ready to be sent through a channel provider (Spec 004).

  `body` is already rendered; `metadata` is for the caller's own bookkeeping and is
  never sent to the provider. `idempotency_key` must be stable across retries of the
  same dispatch so providers that deduplicate can do so.
  """

  @channels [:sms, :whatsapp]
  @max_body_length 4096
  @e164 ~r/^\+[1-9][0-9]{7,14}$/

  @enforce_keys [:channel, :to, :body, :idempotency_key]
  defstruct tenant_id: nil,
            channel: nil,
            to: nil,
            body: nil,
            idempotency_key: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t() | nil,
          channel: Notifiq.Channels.Provider.channel(),
          to: String.t(),
          body: String.t(),
          idempotency_key: String.t(),
          metadata: map()
        }

  @doc "Channels known to the platform."
  @spec channels() :: [Notifiq.Channels.Provider.channel(), ...]
  def channels, do: @channels

  @doc "Checks the message is well formed before any provider is called (FR-6)."
  @spec validate(term()) :: :ok | {:error, :invalid_message}
  def validate(%__MODULE__{} = message) do
    if valid_channel?(message.channel) and valid_phone?(message.to) and
         valid_body?(message.body) and valid_key?(message.idempotency_key) do
      :ok
    else
      {:error, :invalid_message}
    end
  end

  def validate(_other), do: {:error, :invalid_message}

  defp valid_channel?(channel), do: channel in @channels

  defp valid_phone?(to), do: is_binary(to) and to =~ @e164

  defp valid_body?(body) do
    is_binary(body) and String.trim(body) != "" and String.length(body) <= @max_body_length
  end

  defp valid_key?(key), do: is_binary(key) and key != ""
end
