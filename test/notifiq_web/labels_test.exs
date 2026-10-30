defmodule NotifiqWeb.LabelsTest do
  use ExUnit.Case, async: true

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Mensageria.CreditTransaction
  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Mensageria.MessageLog
  alias NotifiqWeb.Labels

  test "every event type has its own words, not the raw key" do
    for type <- EventTypes.all() do
      assert Labels.event_type(type) != type
    end

    assert Labels.event_type("something_new") == "something_new"
  end

  test "every channel the core knows is written the way people write it" do
    for channel <- OutboundMessage.channels() do
      assert Labels.channel(Atom.to_string(channel)) =~ ~r/^(SMS|WhatsApp)$/
    end

    assert Labels.channel("voice") == "VOICE"
  end

  test "every message status has a label and a tone" do
    for status <- MessageLog.statuses() do
      {label, tone} = Labels.message_status(status)
      assert label != status
      assert tone in [:ok, :error, :warn, :neutral]
    end

    assert Labels.message_status("mystery") == {"mystery", :neutral}
  end

  test "every ledger reason has a label" do
    for reason <- CreditTransaction.reasons() do
      assert Labels.credit_reason(reason) != "Lançamento"
    end

    assert Labels.credit_reason("other") == "Lançamento"
  end

  test "a delivery is the channel and the provider's key" do
    assert Labels.delivery("acme", "sms") == "SMS · acme"
  end

  describe "failure_reason/1" do
    test "translates the reasons the providers and the worker produce" do
      assert Labels.failure_reason("invalid_number") =~ "número"
      assert Labels.failure_reason("recipient_unsubscribed") =~ "não receber"
      assert Labels.failure_reason("stale") =~ "parada na fila"
      assert Labels.failure_reason("retries_exhausted") =~ "tentativas"
    end

    test "never shows an unknown code, and nil stays nil" do
      assert Labels.failure_reason("some_new_code") == "O envio não foi concluído."
      refute Labels.failure_reason("some_new_code") =~ "some_new_code"
      assert Labels.failure_reason(nil) == nil
    end
  end

  test "credit_outcome/1 says what happened to the credit" do
    assert Labels.credit_outcome("failed") =~ "devolvido"
    assert Labels.credit_outcome("unconfirmed") =~ "mantido"
    assert Labels.credit_outcome("pending") =~ "reservado"
    assert Labels.credit_outcome("uncertain") =~ "reservado"
    assert Labels.credit_outcome("sent") == nil
  end
end
