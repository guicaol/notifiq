defmodule Notifiq.Channels.OutboundMessageTest do
  use ExUnit.Case, async: true

  alias Notifiq.Channels.OutboundMessage

  defp message(overrides \\ []) do
    struct!(
      %OutboundMessage{
        channel: :sms,
        to: "+5511999998888",
        body: "Olá",
        idempotency_key: "k-1"
      },
      overrides
    )
  end

  test "channels/0 lists the platform channels" do
    assert OutboundMessage.channels() == [:sms, :whatsapp]
  end

  test "validate/1 accepts a well formed message" do
    assert :ok = OutboundMessage.validate(message())
    assert :ok = OutboundMessage.validate(message(channel: :whatsapp))
    assert :ok = OutboundMessage.validate(message(body: String.duplicate("a", 4096)))
  end

  test "validate/1 rejects phones that are not E.164" do
    bad = ["11999998888", "5511999998888", "+0511999998888", "+55", "+55 11 99999-8888", "", nil]

    for to <- bad do
      assert {:error, :invalid_message} = OutboundMessage.validate(message(to: to)), inspect(to)
    end
  end

  test "validate/1 rejects blank or oversized bodies" do
    for body <- ["", "   \n", nil, String.duplicate("a", 4097), 123] do
      assert {:error, :invalid_message} = OutboundMessage.validate(message(body: body)),
             inspect(body)
    end
  end

  test "validate/1 rejects unknown channels and empty idempotency keys" do
    for channel <- [:email, :pigeon, "sms", nil] do
      assert {:error, :invalid_message} = OutboundMessage.validate(message(channel: channel))
    end

    for key <- ["", nil, :atom] do
      assert {:error, :invalid_message} = OutboundMessage.validate(message(idempotency_key: key))
    end
  end

  test "validate/1 rejects anything that is not an OutboundMessage" do
    assert {:error, :invalid_message} = OutboundMessage.validate(%{channel: :sms})
    assert {:error, :invalid_message} = OutboundMessage.validate(nil)
  end
end
