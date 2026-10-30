defmodule Notifiq.Test.OtherFakeProvider do
  @moduledoc "Second fake provider (SMS and WhatsApp), used to prove isolation between providers."

  @behaviour Notifiq.Channels.Provider

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt

  @impl true
  def provider_key, do: :fake_multi

  @impl true
  def supported_channels, do: [:sms, :whatsapp]

  @impl true
  def send_message(%OutboundMessage{} = message, _credentials) do
    {:ok,
     %SendReceipt{
       provider: Atom.to_string(provider_key()),
       provider_message_id: "multi-" <> message.idempotency_key,
       status: :sent
     }}
  end
end
