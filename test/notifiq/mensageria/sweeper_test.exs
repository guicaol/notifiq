defmodule Notifiq.Mensageria.SweeperTest do
  # Not async: it sweeps every tenant, and each test backdates rows it created itself.
  use Notifiq.DataCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  # The sweeper logs a warning whenever it closes something; keep the run output quiet.
  @moduletag :capture_log

  import Ecto.Query
  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Mensageria.Sweeper

  @two_hours 2 * 3_600

  defp backdate(log, seconds \\ @two_hours) do
    old = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [updated_at: old])
    log
  end

  defp stored(tenant, log), do: Mensageria.get_message_log(tenant.id, log.id)

  defp with_status(log, status) do
    Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [status: status])
    log
  end

  defp enqueue_job(log, state) do
    {:ok, job} =
      Oban.insert(DispatchWorker.new(%{tenant_id: log.tenant_id, message_log_id: log.id}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end

  setup do
    %{tenant: tenant!(5)}
  end

  describe "perform/1 (AC-11)" do
    test "closes a stale pending log with no job, refunding the credit", %{tenant: tenant} do
      log = tenant |> reserve!() |> backdate()
      assert balance(tenant) == 4

      assert :ok = perform_job(Sweeper, %{})

      assert %MessageLog{status: "failed", last_error_reason: "stale"} = stored(tenant, log)
      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "closes a stale uncertain log as unconfirmed, keeping the credit", %{tenant: tenant} do
      log = tenant |> reserve!() |> with_status("uncertain") |> backdate()

      assert :ok = perform_job(Sweeper, %{})

      assert %MessageLog{status: "unconfirmed"} = stored(tenant, log)
      assert balance(tenant) == 4
      assert_invariant!(tenant.id)
    end

    test "leaves recent logs alone", %{tenant: tenant} do
      log = reserve!(tenant)
      recent = backdate(reserve!(tenant), 60)

      assert :ok = perform_job(Sweeper, %{})

      assert %MessageLog{status: "pending"} = stored(tenant, log)
      assert %MessageLog{status: "pending"} = stored(tenant, recent)
      assert balance(tenant) == 3
    end

    test "leaves alone a log that still has an active job, however old", %{tenant: tenant} do
      for state <- ["available", "scheduled", "executing", "retryable"] do
        log = tenant |> reserve!() |> backdate()
        enqueue_job(log, state)

        assert :ok = perform_job(Sweeper, %{})

        assert %MessageLog{status: "pending"} = stored(tenant, log), "job #{state}"
      end

      assert balance(tenant) == 1
    end

    test "sweeps a log whose job already ended without finishing it", %{tenant: tenant} do
      for state <- ["discarded", "cancelled", "completed"] do
        log = tenant |> reserve!() |> backdate()
        enqueue_job(log, state)

        assert :ok = perform_job(Sweeper, %{})

        assert %MessageLog{status: "failed"} = stored(tenant, log), "job #{state}"
      end

      assert balance(tenant) == 5
      assert_invariant!(tenant.id)
    end

    test "ignores logs that are already final", %{tenant: tenant} do
      sent = tenant |> reserve!() |> with_status("sent") |> backdate()
      failed = tenant |> reserve!() |> with_status("failed") |> backdate()
      unconfirmed = tenant |> reserve!() |> with_status("unconfirmed") |> backdate()

      assert :ok = perform_job(Sweeper, %{})

      assert stored(tenant, sent).status == "sent"
      assert stored(tenant, failed).status == "failed"
      assert stored(tenant, unconfirmed).status == "unconfirmed"
      assert balance(tenant) == 2
    end

    test "is idempotent: a second run changes nothing", %{tenant: tenant} do
      log = tenant |> reserve!() |> backdate()

      assert :ok = perform_job(Sweeper, %{})
      closed = stored(tenant, log)
      assert :ok = perform_job(Sweeper, %{})

      assert stored(tenant, log) == closed
      assert balance(tenant) == 5
    end

    test "handles each tenant separately", %{tenant: tenant} do
      other = tenant!(5)
      mine = tenant |> reserve!() |> backdate()
      theirs = other |> reserve!() |> backdate()
      protected = other |> reserve!() |> backdate()
      enqueue_job(protected, "executing")

      assert :ok = perform_job(Sweeper, %{})

      assert stored(tenant, mine).status == "failed"
      assert stored(other, theirs).status == "failed"
      assert stored(other, protected).status == "pending"
      assert balance(tenant) == 5
      assert balance(other) == 4
      assert_invariant!(tenant.id)
      assert_invariant!(other.id)
    end

    test "respects the configured staleness window", %{tenant: tenant} do
      original = Application.get_env(:notifiq, :dispatch, [])
      Application.put_env(:notifiq, :dispatch, Keyword.put(original, :stale_after, 10_800))
      on_exit(fn -> Application.put_env(:notifiq, :dispatch, original) end)

      log = tenant |> reserve!() |> backdate(@two_hours)

      assert :ok = perform_job(Sweeper, %{})

      assert stored(tenant, log).status == "pending"
    end
  end

  describe "list_stale_logs/3" do
    test "is filtered by tenant", %{tenant: tenant} do
      other = tenant!(5)
      mine = tenant |> reserve!() |> backdate()
      _theirs = other |> reserve!() |> backdate()
      cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert [%MessageLog{id: id}] = Mensageria.list_stale_logs(tenant.id, cutoff)
      assert id == mine.id
    end

    test "returns the oldest first and honours the limit", %{tenant: tenant} do
      newer = tenant |> reserve!() |> backdate(@two_hours)
      older = tenant |> reserve!() |> backdate(@two_hours * 2)
      cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert [first, second] = Mensageria.list_stale_logs(tenant.id, cutoff)
      assert [first.id, second.id] == [older.id, newer.id]

      assert [%MessageLog{id: id}] = Mensageria.list_stale_logs(tenant.id, cutoff, limit: 1)
      assert id == older.id
    end
  end

  test "runs in the maintenance queue, once per scheduled run" do
    assert %{queue: "maintenance", max_attempts: 1} = Sweeper.new(%{}).changes
  end
end
