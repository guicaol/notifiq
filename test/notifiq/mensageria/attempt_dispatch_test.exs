defmodule Notifiq.Mensageria.AttemptDispatchTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.MessageLog

  defp reserve_with(tenant, body, overrides \\ %{}) do
    reserve!(tenant, Map.merge(%{body: body}, overrides))
  end

  setup do
    %{tenant: tenant!(5)}
  end

  describe "attempt_dispatch/2 (AC-11)" do
    test "sends through the provider with the log id as idempotency key and settles the log",
         %{tenant: tenant} do
      log = reserve_with(tenant, "Seu pedido foi faturado")

      assert {:ok, %MessageLog{} = sent} = Mensageria.attempt_dispatch(tenant.id, log.id)

      assert sent.status == "sent"
      assert sent.attempts == 1
      # the fake provider derives the message id from the idempotency key it received
      assert sent.provider_message_id == "fake-" <> log.id
      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "never sends a settled log again", %{tenant: tenant} do
      log = reserve_with(tenant, "Olá")
      {:ok, sent} = Mensageria.attempt_dispatch(tenant.id, log.id)

      assert {:error, :already_final} = Mensageria.attempt_dispatch(tenant.id, log.id)

      reloaded = Mensageria.get_message_log(tenant.id, log.id)
      assert reloaded.attempts == 1
      assert reloaded.updated_at == sent.updated_at
      assert balance(tenant) == 4
    end

    test "a permanent provider failure fails the log and refunds", %{tenant: tenant} do
      log = reserve_with(tenant, "[scenario:permanent] Olá")

      assert {:ok, %MessageLog{status: "failed", last_error_reason: "invalid_number"}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "a retryable failure leaves the log pending for another attempt", %{tenant: tenant} do
      log = reserve_with(tenant, "[scenario:retryable] Olá")

      assert {:ok, %MessageLog{status: "pending", attempts: 1}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert {:ok, %MessageLog{status: "pending", attempts: 2}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert balance(tenant) == 4
    end

    test "an uncertain failure keeps the credit and can be attempted again", %{tenant: tenant} do
      log = reserve_with(tenant, "[scenario:uncertain] Olá")

      assert {:ok, %MessageLog{status: "uncertain"}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert {:ok, %MessageLog{status: "uncertain", attempts: 2}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert balance(tenant) == 4
    end

    test "an unknown provider is a permanent failure: failed and refunded", %{tenant: tenant} do
      log = reserve_with(tenant, "Olá", %{provider: "does_not_exist"})

      assert {:ok, %MessageLog{status: "failed", last_error_reason: "unknown_provider"}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert balance(tenant) == 5
    end

    test "a channel the provider can't serve is a permanent failure: failed and refunded",
         %{tenant: tenant} do
      log = reserve_with(tenant, "Olá", %{channel: :whatsapp})

      assert {:ok, %MessageLog{status: "failed", last_error_reason: "unsupported_channel"}} =
               Mensageria.attempt_dispatch(tenant.id, log.id)

      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "an unknown log is :not_found", %{tenant: tenant} do
      assert {:error, :not_found} = Mensageria.attempt_dispatch(tenant.id, Ecto.UUID.generate())
    end
  end

  describe "to_outbound_message/1" do
    test "maps the stored log to the provider-facing message", %{tenant: tenant} do
      log = reserve_with(tenant, "Olá mundo")

      assert %OutboundMessage{} = message = Mensageria.to_outbound_message(log)
      assert message.tenant_id == tenant.id
      assert message.channel == :sms
      assert message.to == "+5511999998888"
      assert message.body == "Olá mundo"
      assert message.idempotency_key == log.id
      assert :ok = OutboundMessage.validate(message)
    end
  end
end
