defmodule Notifiq.Channels.DispatcherTest do
  # Not async: telemetry handlers and log capture are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notifiq.Channels.Dispatcher
  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt

  @phone "+5511999998888"
  @body "Segredo do pedido 1234"

  defp message(overrides \\ []) do
    struct!(
      %OutboundMessage{
        channel: :sms,
        to: @phone,
        body: @body,
        idempotency_key: "key-#{System.unique_integer([:positive])}",
        metadata: %{notify: self()}
      },
      overrides
    )
  end

  defp with_scenario(scenario), do: message(metadata: %{notify: self(), scenario: scenario})

  describe "successful dispatch" do
    test "AC-2: returns the provider's receipt" do
      msg = message()

      assert {:ok, %SendReceipt{} = receipt} = Dispatcher.dispatch("fake_sms", msg)
      assert receipt.provider == "fake_sms"
      assert receipt.provider_message_id == "fake-" <> msg.idempotency_key
      assert receipt.status == :queued
    end

    test "dispatches through any registered provider and channel" do
      assert {:ok, %SendReceipt{provider: "fake_multi"}} =
               Dispatcher.dispatch("fake_multi", message(channel: :whatsapp))
    end

    test "AC-11: hands the provider the credentials configured for its key" do
      Dispatcher.dispatch("fake_sms", message())

      assert_received {:provider_called, %OutboundMessage{}, %{api_key: "test-api-key"}}
    end
  end

  describe "checks that never reach the provider" do
    test "AC-1: an unknown provider is a permanent error" do
      assert {:error, {:permanent, :unknown_provider}} = Dispatcher.dispatch("nope", message())

      assert {:error, {:permanent, :unknown_provider}} =
               Dispatcher.dispatch("Fake_SMS", message())

      refute_received {:provider_called, _, _}
    end

    test "AC-3: an unsupported channel is permanent and the provider is not called" do
      assert {:error, {:permanent, :unsupported_channel}} =
               Dispatcher.dispatch("fake_sms", message(channel: :whatsapp))

      refute_received {:provider_called, _, _}
    end

    test "AC-4: an invalid message is permanent and the provider is not called" do
      invalid = [[to: "11999998888"], [body: ""], [channel: :email], [idempotency_key: ""]]

      for overrides <- invalid do
        assert {:error, {:permanent, :invalid_message}} =
                 Dispatcher.dispatch("fake_sms", message(overrides))
      end

      assert {:error, {:permanent, :invalid_message}} = Dispatcher.dispatch("fake_sms", %{})
      refute_received {:provider_called, _, _}
    end
  end

  describe "error classification" do
    test "AC-5: the provider's class and reason are passed through" do
      assert {:error, {:retryable, :rate_limited}} =
               Dispatcher.dispatch("fake_sms", with_scenario(:retryable))

      assert {:error, {:permanent, :invalid_number}} =
               Dispatcher.dispatch("fake_sms", with_scenario(:permanent))

      assert {:error, {:uncertain, :connection_reset}} =
               Dispatcher.dispatch("fake_sms", with_scenario(:uncertain))
    end

    test "AC-9: a return value outside the contract is :uncertain" do
      log =
        capture_log(fn ->
          assert {:error, {:uncertain, :invalid_provider_response}} =
                   Dispatcher.dispatch("fake_sms", with_scenario(:bad_return))

          assert {:error, {:uncertain, :invalid_provider_response}} =
                   Dispatcher.dispatch("fake_sms", with_scenario(:bad_reason))
        end)

      assert log =~ "provider returned an invalid value provider_key=fake_sms"
      refute log =~ "free text from the provider"
    end
  end

  describe "provider failures (FR-9, FR-10)" do
    test "AC-7: an exception is :uncertain, logged by key and without personal data" do
      log =
        capture_log(fn ->
          assert {:error, {:uncertain, :provider_crashed}} =
                   Dispatcher.dispatch("fake_sms", with_scenario(:raise))
        end)

      assert log =~ "provider raised provider_key=fake_sms channel=sms error=RuntimeError"
      refute log =~ @phone
      refute log =~ @body
      refute log =~ "test-api-key"

      # another provider keeps working right after
      assert {:ok, %SendReceipt{provider: "fake_multi"}} =
               Dispatcher.dispatch("fake_multi", message())
    end

    test "AC-8: a provider over the timeout is :uncertain and never hangs the caller" do
      log =
        capture_log(fn ->
          {micros, result} =
            :timer.tc(fn -> Dispatcher.dispatch("fake_sms", with_scenario(:sleep)) end)

          assert {:error, {:uncertain, :timeout}} = result
          assert micros < 2_000_000
        end)

      assert log =~ "provider timed out provider_key=fake_sms"
      refute log =~ @phone
    end
  end

  describe "telemetry (FR-11)" do
    def handle_event(_event, measurements, metadata, pid) do
      send(pid, {:telemetry, measurements, metadata})
    end

    setup do
      id = "dispatcher-test-#{System.unique_integer([:positive])}"
      :telemetry.attach(id, [:notifiq, :channels, :dispatch], &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "AC-12: emits provider, channel and outcome for success and each error class" do
      capture_log(fn ->
        Dispatcher.dispatch("fake_sms", message())
        Dispatcher.dispatch("fake_sms", with_scenario(:retryable))
        Dispatcher.dispatch("fake_sms", with_scenario(:permanent))
        Dispatcher.dispatch("fake_sms", with_scenario(:uncertain))
        Dispatcher.dispatch("nope", message())
      end)

      assert_received {:telemetry, %{duration: duration},
                       %{provider: "fake_sms", channel: :sms, outcome: :ok}}

      assert is_integer(duration) and duration >= 0
      assert_received {:telemetry, _, %{provider: "fake_sms", outcome: :retryable}}
      assert_received {:telemetry, _, %{provider: "fake_sms", outcome: :permanent}}
      assert_received {:telemetry, _, %{provider: "fake_sms", outcome: :uncertain}}
      assert_received {:telemetry, _, %{provider: "nope", outcome: :permanent}}
    end
  end
end
