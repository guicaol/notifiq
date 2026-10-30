defmodule Notifiq.Channels.OtherProviderContractTest do
  use Notifiq.Channels.ProviderContractCase,
    provider: Notifiq.Test.OtherFakeProvider,
    valid_message: %Notifiq.Channels.OutboundMessage{
      channel: :whatsapp,
      to: "+5511988887777",
      body: "Olá!",
      idempotency_key: "msg-3"
    }
end
