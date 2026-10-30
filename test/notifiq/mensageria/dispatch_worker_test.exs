defmodule Notifiq.Mensageria.DispatchWorkerTest do
  # Not async: some tests change application env (resend policy, attempt module).
  use Notifiq.DataCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.MessageLog

  @max_attempts 6

  setup do
    tenant = tenant!(5)
    %{tenant: tenant}
  end

  defp reserved(tenant, scenario) do
    body = if scenario == :ok, do: "Olá", else: "[scenario:#{scenario}] Olá"
    reserve!(tenant, %{body: body})
  end

  defp run(log, attempt \\ 1) do
    perform_job(
      DispatchWorker,
      %{tenant_id: log.tenant_id, message_log_id: log.id},
      attempt: attempt,
      max_attempts: @max_attempts
    )
  end

  defp stored(tenant, log), do: Mensageria.get_message_log(tenant.id, log.id)

  defp put_dispatch(key, value) do
    original = Application.get_env(:notifiq, :dispatch, [])
    Application.put_env(:notifiq, :dispatch, Keyword.put(original, key, value))
    on_exit(fn -> Application.put_env(:notifiq, :dispatch, original) end)
  end

  describe "outcomes (AC-6)" do
    test "a delivered message finishes the job", %{tenant: tenant} do
      log = reserved(tenant, :ok)

      assert :ok = run(log)

      assert %MessageLog{status: "sent", attempts: 1} = stored(tenant, log)
      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "a permanent failure finishes the job without retrying, refunded", %{tenant: tenant} do
      log = reserved(tenant, :permanent)

      assert :ok = run(log)

      assert %MessageLog{status: "failed", attempts: 1} = stored(tenant, log)
      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "a retryable failure asks Oban to retry and keeps the credit reserved", %{tenant: tenant} do
      log = reserved(tenant, :retryable)

      assert {:error, "retryable: rate_limited"} = run(log)

      assert %MessageLog{status: "pending", attempts: 1} = stored(tenant, log)
      assert balance(tenant) == 4
    end

    test "retries keep going until the last attempt", %{tenant: tenant} do
      log = reserved(tenant, :retryable)

      for attempt <- 1..(@max_attempts - 1) do
        assert {:error, _reason} = run(log, attempt)
      end

      assert %MessageLog{status: "pending", attempts: 5} = stored(tenant, log)
      assert balance(tenant) == 4
    end

    test "on the last attempt a still-retryable message is given up and refunded", %{
      tenant: tenant
    } do
      log = reserved(tenant, :retryable)

      assert {:cancel, :retries_exhausted} = run(log, @max_attempts)

      assert %MessageLog{status: "failed", last_error_class: "gave_up"} = stored(tenant, log)
      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "an unknown provider fails permanently and refunds", %{tenant: tenant} do
      log = reserve!(tenant, %{provider: "does_not_exist"})

      assert :ok = run(log)

      assert %MessageLog{status: "failed", last_error_reason: "unknown_provider"} =
               stored(tenant, log)

      assert balance(tenant) == 5
    end
  end

  describe "uncertain outcomes (AC-9)" do
    test "by default are never resent: closed as unconfirmed, credit kept", %{tenant: tenant} do
      log = reserved(tenant, :uncertain)

      assert {:cancel, :uncertain_not_resent} = run(log)

      assert %MessageLog{status: "unconfirmed", attempts: 1} = stored(tenant, log)
      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "can be resent a configured number of times, then are closed as unconfirmed",
         %{tenant: tenant} do
      put_dispatch(:uncertain_resends, 2)
      log = reserved(tenant, :uncertain)

      assert {:error, "uncertain: connection_reset"} = run(log, 1)
      assert {:error, "uncertain: connection_reset"} = run(log, 2)
      assert %MessageLog{status: "uncertain", attempts: 2} = stored(tenant, log)

      assert {:cancel, :uncertain_not_resent} = run(log, 3)

      assert %MessageLog{status: "unconfirmed", attempts: 3} = stored(tenant, log)
      assert balance(tenant) == 4
    end

    test "the last attempt closes the log even if resends remain", %{tenant: tenant} do
      put_dispatch(:uncertain_resends, 100)
      log = reserved(tenant, :uncertain)

      assert {:cancel, :retries_exhausted} = run(log, @max_attempts)

      assert %MessageLog{status: "unconfirmed"} = stored(tenant, log)
      assert balance(tenant) == 4
    end
  end

  describe "never sends twice (AC-7)" do
    test "running the job again after a delivery doesn't call the provider", %{tenant: tenant} do
      log = reserved(tenant, :ok)
      assert :ok = run(log)
      settled = stored(tenant, log)

      assert :ok = run(log, 2)

      assert stored(tenant, log) == settled
      assert stored(tenant, log).attempts == 1
      assert balance(tenant) == 4
    end

    test "failed and unconfirmed logs are left alone too", %{tenant: tenant} do
      failed = reserved(tenant, :permanent)
      assert :ok = run(failed)

      unconfirmed = reserved(tenant, :uncertain)
      assert {:cancel, _reason} = run(unconfirmed)

      before_failed = stored(tenant, failed)
      before_unconfirmed = stored(tenant, unconfirmed)

      assert :ok = run(failed, 2)
      assert :ok = run(unconfirmed, 2)

      assert stored(tenant, failed) == before_failed
      assert stored(tenant, unconfirmed) == before_unconfirmed
      assert_invariant!(tenant.id)
    end

    test "a log that no longer exists cancels the job", %{tenant: tenant} do
      ghost = %MessageLog{id: Ecto.UUID.generate(), tenant_id: tenant.id}

      assert {:cancel, :message_log_not_found} = run(ghost)
    end

    test "a job can't touch another tenant's log", %{tenant: tenant} do
      log = reserved(tenant, :ok)
      other = tenant!(5)

      assert {:cancel, :message_log_not_found} = run(%{log | tenant_id: other.id})

      assert %MessageLog{status: "pending"} = stored(tenant, log)
    end
  end

  describe "a crash inside the worker (AC-10)" do
    setup do
      original = Application.get_env(:notifiq, :dispatch_attempt_module)
      Application.put_env(:notifiq, :dispatch_attempt_module, Notifiq.Test.CrashingAttempt)

      on_exit(fn ->
        if original,
          do: Application.put_env(:notifiq, :dispatch_attempt_module, original),
          else: Application.delete_env(:notifiq, :dispatch_attempt_module)
      end)
    end

    test "on an early attempt the exception propagates and the log is untouched", %{
      tenant: tenant
    } do
      log = reserved(tenant, :ok)

      assert_raise RuntimeError, "the database went away", fn -> run(log, 1) end

      assert %MessageLog{status: "pending", attempts: 0} = stored(tenant, log)
      assert balance(tenant) == 4
    end

    test "on the last attempt the log is closed and refunded, and the exception still propagates",
         %{tenant: tenant} do
      log = reserved(tenant, :ok)

      assert_raise RuntimeError, "the database went away", fn -> run(log, @max_attempts) end

      assert %MessageLog{status: "failed", last_error_reason: "worker_crashed"} =
               stored(tenant, log)

      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "cleanup of a log that can't be closed never hides the original error", %{tenant: tenant} do
      ghost = %MessageLog{id: Ecto.UUID.generate(), tenant_id: tenant.id}

      assert_raise RuntimeError, "the database went away", fn -> run(ghost, @max_attempts) end
    end
  end

  describe "job definition" do
    test "AC-12: only one active job exists per message log", %{tenant: tenant} do
      log = reserved(tenant, :ok)
      args = %{tenant_id: log.tenant_id, message_log_id: log.id}

      assert {:ok, first} = Oban.insert(DispatchWorker.new(args))
      assert {:ok, second} = Oban.insert(DispatchWorker.new(args))

      assert second.conflict?
      assert second.id == first.id
      assert [_one] = all_enqueued(worker: DispatchWorker)
    end

    test "different logs get different jobs", %{tenant: tenant} do
      for _ <- 1..2 do
        log = reserved(tenant, :ok)

        {:ok, _job} =
          Oban.insert(DispatchWorker.new(%{tenant_id: log.tenant_id, message_log_id: log.id}))
      end

      assert length(all_enqueued(worker: DispatchWorker)) == 2
    end

    test "runs in its own queue, apart from ingestion" do
      assert %{queue: "dispatch", max_attempts: @max_attempts} =
               DispatchWorker.new(%{tenant_id: "t", message_log_id: "l"}).changes
    end

    test "backoff grows with the attempt number and times are bounded" do
      first = DispatchWorker.backoff(%Oban.Job{attempt: 1})
      third = DispatchWorker.backoff(%Oban.Job{attempt: 3})

      assert first in 24..36
      assert third in 96..144
      assert DispatchWorker.timeout(%Oban.Job{}) == 60_000
    end
  end
end
