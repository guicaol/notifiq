defmodule Notifiq.Channels.TwilioContractTest do
  # Spec 005, AC-1: the Twilio provider passes the shared contract suite from Spec 004.
  use Notifiq.Channels.ProviderContractCase,
    provider: Notifiq.Channels.Twilio,
    valid_message: %Notifiq.Channels.OutboundMessage{
      channel: :sms,
      to: "+5511999998888",
      body: "Seu pedido foi faturado",
      idempotency_key: "twilio-contract-1"
    },
    credentials: %{
      account_sid: "AC00000000000000000000000000000000",
      auth_token: "test-twilio-token",
      sms_from: "+15005550006"
    },
    setup: {Notifiq.Test.TwilioStub, :install},
    error_message: %Notifiq.Channels.OutboundMessage{
      channel: :sms,
      to: "+5511000000001",
      body: "Seu pedido foi faturado",
      idempotency_key: "twilio-contract-2"
    }
end
