defmodule Notifiq.Mensageria.ConcurrencyTest do
  # Spec 006, AC-4/AC-5/AC-9. The SQL sandbox funnels every process through one
  # connection, which would hide exactly the races these tests exist to catch. So the
  # data here is committed through real connections (`unboxed_run`) and removed in
  # `on_exit`. The module is not async: sync modules never overlap with each other, and
  # the async ones have already finished by the time it runs.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import Ecto.Query
  import Notifiq.Test.MensageriaHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Repo

  @prefix "concurrency-test"
  @workers 10

  setup do
    unboxed(&cleanup/0)
    on_exit(fn -> unboxed(&cleanup/0) end)
    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp cleanup do
    tenants = "SELECT id FROM tenants WHERE name LIKE '#{@prefix}%'"

    for sql <- [
          "DELETE FROM oban_jobs WHERE args->>'tenant_id' IN (SELECT id::text FROM tenants WHERE name LIKE '#{@prefix}%')",
          "DELETE FROM credit_transactions WHERE tenant_id IN (#{tenants})",
          "DELETE FROM message_logs WHERE tenant_id IN (#{tenants})",
          "DELETE FROM integrations WHERE tenant_id IN (#{tenants})",
          "DELETE FROM message_templates WHERE tenant_id IN (#{tenants})",
          "DELETE FROM webhook_events WHERE external_event_id LIKE '#{@prefix}%'",
          "DELETE FROM tenants WHERE name LIKE '#{@prefix}%'"
        ] do
      Repo.query!(sql)
    end

    :ok
  end

  # Runs `fun.(index)` in `@workers` processes, each on its own database connection,
  # released together so the calls really overlap.
  defp race(fun) do
    tasks =
      for index <- 1..@workers do
        Task.async(fn ->
          receive do
            :go -> unboxed(fn -> fun.(index) end)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end

  defp count_by(results, matcher), do: Enum.count(results, matcher)

  defp tenant_with_event(credits) do
    tenant = tenant!(credits, @prefix)
    {tenant, event!(tenant, @prefix)}
  end

  defp tenant_with_events(credits, count) do
    tenant = tenant!(credits, @prefix)
    {tenant, for(_ <- 1..count, do: event!(tenant, @prefix))}
  end

  # `reserve!/2` from the helpers would create its event with the default prefix, which
  # `cleanup/0` doesn't know: committed data must always carry `@prefix`.
  defp reserve_committed!(tenant) do
    {:ok, log} = Mensageria.reserve(reservation(tenant, event!(tenant, @prefix)))
    log
  end

  test "AC-4: parallel reservations of one event produce one log and one debit" do
    {tenant, event} = unboxed(fn -> tenant_with_event(5) end)

    results = race(fn _index -> Mensageria.reserve(reservation(tenant, event)) end)

    assert count_by(results, &match?({:ok, %MessageLog{}}, &1)) == 1
    assert count_by(results, &match?({:duplicate, %MessageLog{}}, &1)) == @workers - 1

    unboxed(fn ->
      assert balance(tenant) == 4
      assert [_only_log] = Mensageria.list_message_logs(tenant.id)
      assert_invariant!(tenant.id)
    end)
  end

  test "AC-5: with credit for K of N reservations, exactly K win and the balance never goes negative" do
    credits = 3

    {tenant, events} =
      unboxed(fn -> tenant_with_events(credits, @workers) end)

    results =
      race(fn index -> Mensageria.reserve(reservation(tenant, Enum.at(events, index - 1))) end)

    assert count_by(results, &match?({:ok, %MessageLog{}}, &1)) == credits
    assert count_by(results, &(&1 == {:error, :insufficient_credits})) == @workers - credits

    unboxed(fn ->
      assert balance(tenant) == 0
      assert length(Mensageria.list_message_logs(tenant.id)) == credits
      assert_invariant!(tenant.id)
    end)
  end

  test "AC-5: racing tenants don't interfere with each other's balance" do
    {{rich, rich_events}, {poor, poor_events}} =
      unboxed(fn ->
        {tenant_with_events(@workers, @workers), tenant_with_events(2, @workers)}
      end)

    results =
      race(fn index ->
        {Mensageria.reserve(reservation(rich, Enum.at(rich_events, index - 1))),
         Mensageria.reserve(reservation(poor, Enum.at(poor_events, index - 1)))}
      end)

    assert count_by(results, &match?({{:ok, _}, _}, &1)) == @workers
    assert count_by(results, &match?({_, {:ok, _}}, &1)) == 2

    unboxed(fn ->
      assert balance(rich) == 0
      assert balance(poor) == 0
      assert_invariant!(rich.id)
      assert_invariant!(poor.id)
    end)
  end

  test "AC-9: the same failure recorded in parallel refunds exactly once" do
    log =
      unboxed(fn ->
        tenant = tenant!(1, @prefix)
        reserve_committed!(tenant)
      end)

    failure = {:error, {:permanent, :invalid_number}}
    results = race(fn _index -> Mensageria.record_outcome(log, failure) end)

    assert count_by(results, &match?({:ok, %MessageLog{status: "failed"}}, &1)) == 1
    assert count_by(results, &(&1 == {:error, :already_final})) == @workers - 1

    unboxed(fn ->
      assert Mensageria.credit_balance(log.tenant_id) == 1
      assert ledger_count(log.tenant_id) == 3
      assert_invariant!(log.tenant_id)
    end)
  end

  test "AC-9: a success racing a permanent failure settles on exactly one outcome" do
    log = unboxed(fn -> reserve_committed!(tenant!(1, @prefix)) end)
    receipt = %SendReceipt{provider: "fake_sms", provider_message_id: "SM1", status: :queued}

    results =
      race(fn index ->
        if rem(index, 2) == 0,
          do: Mensageria.record_outcome(log, {:ok, receipt}),
          else: Mensageria.record_outcome(log, {:error, {:permanent, :invalid_number}})
      end)

    assert count_by(results, &match?({:ok, %MessageLog{}}, &1)) == 1

    unboxed(fn ->
      final = Mensageria.get_message_log(log.tenant_id, log.id)
      balance = Mensageria.credit_balance(log.tenant_id)

      # sent keeps the credit spent; failed gives it back. Never both, never neither.
      assert {final.status, balance} in [{"sent", 0}, {"failed", 1}]
      assert_invariant!(log.tenant_id)
    end)
  end

  defp jobs_for(tenant) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == ^inspect(DispatchWorker) and
            fragment("?->>'tenant_id' = ?", j.args, ^tenant.id)
    )
  end

  test "Spec 007 AC-4: parallel request_dispatch of one event leaves one log, one debit, one job" do
    {tenant, event} = unboxed(fn -> tenant_with_event(5) end)

    results = race(fn _index -> Mensageria.request_dispatch(reservation(tenant, event)) end)

    assert count_by(results, &match?({:ok, %MessageLog{}}, &1)) == 1
    assert count_by(results, &match?({:duplicate, %MessageLog{}}, &1)) == @workers - 1

    unboxed(fn ->
      assert balance(tenant) == 4
      assert [_only_log] = Mensageria.list_message_logs(tenant.id)
      assert [_only_job] = jobs_for(tenant)
      assert_invariant!(tenant.id)
    end)
  end

  test "Spec 007: a job exists for exactly the dispatches that were paid for" do
    credits = 3

    {tenant, events} =
      unboxed(fn -> tenant_with_events(credits, @workers) end)

    results =
      race(fn index ->
        Mensageria.request_dispatch(reservation(tenant, Enum.at(events, index - 1)))
      end)

    assert count_by(results, &match?({:ok, %MessageLog{}}, &1)) == credits

    unboxed(fn ->
      logs = Mensageria.list_message_logs(tenant.id)
      jobs = jobs_for(tenant)

      assert length(jobs) == credits

      assert Enum.sort(Enum.map(jobs, & &1.args["message_log_id"])) ==
               Enum.sort(Enum.map(logs, & &1.id))

      assert balance(tenant) == 0
    end)
  end

  test "Spec 008 AC-1: racing to connect one account leaves exactly one owner" do
    tenants = unboxed(fn -> for _ <- 1..@workers, do: tenant!(0, @prefix) end)
    account = "#{@prefix}-account-#{System.unique_integer([:positive])}"

    results =
      race(fn index ->
        Notifiq.Tenants.connect_integration(Enum.at(tenants, index - 1).id, %{
          source: "fake",
          external_account_id: account
        })
      end)

    assert count_by(results, &match?({:ok, %Notifiq.Tenants.Integration{}}, &1)) == 1
    assert count_by(results, &match?({:error, %Ecto.Changeset{}}, &1)) == @workers - 1

    unboxed(fn ->
      assert {:ok, owner} = Notifiq.Tenants.resolve_tenant("fake", account)
      assert owner in Enum.map(tenants, & &1.id)

      owned = Enum.filter(tenants, &(Notifiq.Tenants.list_integrations(&1.id) != []))
      assert [%{id: ^owner}] = owned
    end)
  end

  test "Spec 009 AC-9: the event worker racing itself reserves and charges once" do
    {tenant, event} =
      unboxed(fn ->
        {tenant, event} = tenant_with_event(5)
        template!(tenant)
        {tenant, event}
      end)

    results =
      race(fn _index ->
        perform_job(EventWorker, %{webhook_event_id: event.id, tenant_id: tenant.id})
      end)

    assert Enum.all?(results, &(&1 == :ok))

    unboxed(fn ->
      assert [%MessageLog{status: "pending"}] = Mensageria.list_message_logs(tenant.id)
      assert [_only_job] = jobs_for(tenant)
      assert balance(tenant) == 4
      assert Mensageria.get_webhook_event(tenant.id, event.id).status == "dispatched"
      assert_invariant!(tenant.id)
    end)
  end

  test "Spec 009 AC-2: racing to create a template for one event type leaves exactly one" do
    tenant = unboxed(fn -> tenant!(0, @prefix) end)

    results =
      race(fn index ->
        Notifiq.Templates.create_template(tenant.id, %{
          event_type: "order_created",
          channel: "sms",
          provider: "fake_sms",
          body: "texto #{index}"
        })
      end)

    assert count_by(results, &match?({:ok, %Notifiq.Templates.MessageTemplate{}}, &1)) == 1
    assert count_by(results, &match?({:error, %Ecto.Changeset{}}, &1)) == @workers - 1

    unboxed(fn ->
      assert [%{active: true}] = Notifiq.Templates.list_templates(tenant.id)
    end)
  end
end
