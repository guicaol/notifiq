defmodule Notifiq.Channels.ProviderContractTest do
  # Spec 004, AC-6: the shared contract suite, run here against the fake provider.
  # Real providers (e.g. Twilio, Spec 005) get their own file that `use`s the same case.
  use Notifiq.Channels.ProviderContractCase,
    provider: Notifiq.Test.FakeProvider,
    valid_message: %Notifiq.Channels.OutboundMessage{
      channel: :sms,
      to: "+5511999998888",
      body: "Seu pedido foi faturado",
      idempotency_key: "msg-1"
    },
    credentials: %{api_key: "test-api-key"},
    error_message: %Notifiq.Channels.OutboundMessage{
      channel: :sms,
      to: "+5511999998888",
      body: "Seu pedido foi faturado",
      idempotency_key: "msg-2",
      metadata: %{scenario: :retryable}
    }
end
