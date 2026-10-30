defmodule Notifiq.Mensageria.OutcomeTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.MessageLog

  defp receipt,
    do: %SendReceipt{provider: "fake_sms", provider_message_id: "SM123", status: :queued}

  setup do
    tenant = tenant!(5)
    log = reserve!(tenant)
    %{tenant: tenant, log: log}
  end

  describe "record_outcome/2 transitions (AC-8)" do
    test "success: sent, credit stays spent", %{tenant: tenant, log: log} do
      assert {:ok, %MessageLog{} = sent} = Mensageria.record_outcome(log, {:ok, receipt()})

      assert sent.status == "sent"
      assert sent.attempts == 1
      assert sent.provider_message_id == "SM123"
      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "retryable: stays pending with the attempt recorded, credit stays reserved",
         %{tenant: tenant, log: log} do
      assert {:ok, pending} =
               Mensageria.record_outcome(log, {:error, {:retryable, :rate_limited}})

      assert pending.status == "pending"
      assert pending.attempts == 1
      assert pending.last_error_class == "retryable"
      assert pending.last_error_reason == "rate_limited"
      assert balance(tenant) == 4
    end

    test "uncertain: marked uncertain and NOT refunded, the message may have left",
         %{tenant: tenant, log: log} do
      assert {:ok, uncertain} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})

      assert uncertain.status == "uncertain"
      assert uncertain.last_error_class == "uncertain"
      assert balance(tenant) == 4
      assert ledger_count(tenant.id) == 2
    end

    test "permanent: failed and the credit is refunded with a ledger entry",
         %{tenant: tenant, log: log} do
      assert {:ok, failed} =
               Mensageria.record_outcome(log, {:error, {:permanent, :invalid_number}})

      assert failed.status == "failed"
      assert failed.last_error_reason == "invalid_number"
      assert balance(tenant) == 5

      assert [refund | _] = Mensageria.list_credit_transactions(tenant.id)
      assert refund.reason == "refund"
      assert refund.amount == 1
      assert refund.message_log_id == log.id
      assert_invariant!(tenant.id)
    end

    test "a refund returns the whole cost of the dispatch" do
      tenant = tenant!(10)
      log = reserve!(tenant, %{cost: 4})
      assert balance(tenant) == 6

      assert {:ok, _} = Mensageria.record_outcome(log, {:error, {:permanent, :rejected}})
      assert balance(tenant) == 10
      assert_invariant!(tenant.id)
    end

    test "retries then success: attempts add up and nothing is refunded",
         %{tenant: tenant, log: log} do
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:retryable, :rate_limited}})
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:retryable, :connection_failed}})
      assert {:ok, sent} = Mensageria.record_outcome(log, {:ok, receipt()})

      assert sent.status == "sent"
      assert sent.attempts == 3
      assert sent.last_error_class == nil
      assert balance(tenant) == 4
    end

    test "uncertain, then a successful retry: sent, still charged once", %{
      tenant: tenant,
      log: log
    } do
      {:ok, uncertain} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})

      assert {:ok, %MessageLog{status: "sent", attempts: 2}} =
               Mensageria.record_outcome(uncertain, {:ok, receipt()})

      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "uncertain, then a permanent failure: failed and refunded", %{tenant: tenant, log: log} do
      {:ok, uncertain} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})

      assert {:ok, %MessageLog{status: "failed"}} =
               Mensageria.record_outcome(uncertain, {:error, {:permanent, :invalid_number}})

      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "an outcome outside the Dispatcher contract is refused", %{tenant: tenant, log: log} do
      for bad <- [
            :ok,
            nil,
            {:error, :timeout},
            {:error, {:maybe, :x}},
            {:error, {:permanent, "text"}}
          ] do
        assert {:error, :invalid_outcome} = Mensageria.record_outcome(log, bad)
      end

      assert Mensageria.get_message_log(tenant.id, log.id).status == "pending"
      assert balance(tenant) == 4
    end
  end

  describe "final logs are immutable (AC-9)" do
    test "a settled log refuses new outcomes and changes no money", %{tenant: tenant, log: log} do
      {:ok, sent} = Mensageria.record_outcome(log, {:ok, receipt()})

      for result <- [{:error, {:permanent, :x}}, {:ok, receipt()}, {:error, {:retryable, :x}}] do
        assert {:error, :already_final} = Mensageria.record_outcome(sent, result)
      end

      assert balance(tenant) == 4
      assert ledger_count(tenant.id) == 2
    end

    test "a refund happens once even if the failure is recorded twice", %{
      tenant: tenant,
      log: log
    } do
      failure = {:error, {:permanent, :invalid_number}}

      assert {:ok, failed} = Mensageria.record_outcome(log, failure)
      assert {:error, :already_final} = Mensageria.record_outcome(log, failure)
      assert {:error, :already_final} = Mensageria.record_outcome(failed, failure)

      assert balance(tenant) == 5
      assert ledger_count(tenant.id) == 3
      assert_invariant!(tenant.id)
    end

    test "a log that doesn't exist is :not_found", %{tenant: tenant, log: log} do
      ghost = %{log | id: Ecto.UUID.generate()}

      assert {:error, :not_found} = Mensageria.record_outcome(ghost, {:ok, receipt()})
      assert balance(tenant) == 4
    end

    test "the ledger allows one refund per dispatch", %{tenant: tenant, log: log} do
      {:ok, _} = Mensageria.record_outcome(log, {:error, {:permanent, :x}})

      assert {:error, changeset} =
               Notifiq.Mensageria.Credits.record(Repo, %{
                 tenant_id: tenant.id,
                 message_log_id: log.id,
                 amount: 1,
                 reason: "refund"
               })

      assert %{message_log_id: ["already has an entry for this reason"]} = errors_on(changeset)
    end
  end

  describe "give_up/2 (AC-10)" do
    test "pending becomes failed and is refunded", %{tenant: tenant, log: log} do
      assert {:ok, failed} = Mensageria.give_up(log, :retries_exhausted)

      assert failed.status == "failed"
      assert failed.last_error_class == "gave_up"
      assert failed.last_error_reason == "retries_exhausted"
      assert failed.attempts == 0
      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "pending after retries becomes failed and is refunded", %{tenant: tenant, log: log} do
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:retryable, :rate_limited}})

      assert {:ok, %MessageLog{status: "failed", attempts: 1}} =
               Mensageria.give_up(log, :retries_exhausted)

      assert balance(tenant) == 5
    end

    test "uncertain becomes unconfirmed, with NO refund", %{tenant: tenant, log: log} do
      {:ok, uncertain} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})

      assert {:ok, unconfirmed} = Mensageria.give_up(uncertain, :retries_exhausted)

      assert unconfirmed.status == "unconfirmed"
      assert balance(tenant) == 4
      assert ledger_count(tenant.id) == 2
    end

    test "uses the stored status, not a stale struct", %{tenant: tenant, log: log} do
      {:ok, _uncertain} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})

      # `log` still says pending, the database says uncertain
      assert {:ok, %MessageLog{status: "unconfirmed"}} = Mensageria.give_up(log, :stale)
      assert balance(tenant) == 4
    end

    test "final logs can't be given up on, and nothing is refunded twice", %{
      tenant: tenant,
      log: log
    } do
      {:ok, failed} = Mensageria.give_up(log, :x)

      assert {:error, :already_final} = Mensageria.give_up(failed, :x)
      assert {:error, :already_final} = Mensageria.give_up(log, :x)
      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "a log that doesn't exist is :not_found", %{log: log} do
      assert {:error, :not_found} = Mensageria.give_up(%{log | id: Ecto.UUID.generate()}, :x)
    end
  end
end
