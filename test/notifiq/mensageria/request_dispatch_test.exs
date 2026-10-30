defmodule Notifiq.Mensageria.RequestDispatchTest do
  use Notifiq.DataCase, async: true
  use Oban.Testing, repo: Notifiq.Repo

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.MessageLog

  @phone "+5511999998888"
  @body "Seu pedido 1234 foi faturado"

  defp request(tenant, event, overrides \\ %{}) do
    reservation(tenant, event, Map.merge(%{recipient: @phone, body: @body}, overrides))
  end

  describe "request_dispatch/1 (AC-1)" do
    test "reserves the dispatch and enqueues exactly one job in the same step" do
      tenant = tenant!(5)

      assert {:ok, %MessageLog{} = log} =
               Mensageria.request_dispatch(request(tenant, event!(tenant)))

      assert log.status == "pending"
      assert balance(tenant) == 4
      assert [%{reason: "dispatch"}, _top_up] = Mensageria.list_credit_transactions(tenant.id)

      assert [job] = all_enqueued(worker: DispatchWorker)
      assert job.queue == "dispatch"
      assert job.args == %{"tenant_id" => tenant.id, "message_log_id" => log.id}
      assert_invariant!(tenant.id)
    end

    test "AC-5: the job carries only ids, never the phone number or the text" do
      tenant = tenant!(5)
      {:ok, _log} = Mensageria.request_dispatch(request(tenant, event!(tenant)))

      assert [job] = all_enqueued(worker: DispatchWorker)
      assert Map.keys(job.args) |> Enum.sort() == ["message_log_id", "tenant_id"]

      serialized = Jason.encode!(job.args)
      refute serialized =~ @phone
      refute serialized =~ "pedido"
    end
  end

  describe "nothing is left behind on failure (AC-2)" do
    test "insufficient credits: no log, no debit, no job" do
      tenant = tenant!(1)

      assert {:error, :insufficient_credits} =
               Mensageria.request_dispatch(request(tenant, event!(tenant), %{cost: 2}))

      refute_enqueued(worker: DispatchWorker)
      assert Mensageria.list_message_logs(tenant.id) == []
      assert balance(tenant) == 1
    end

    test "unknown event, unknown tenant and invalid requests enqueue nothing" do
      tenant = tenant!(5)

      assert {:error, :unknown_event} =
               Mensageria.request_dispatch(request(tenant, %{id: Ecto.UUID.generate()}))

      assert {:error, :unknown_tenant} =
               Mensageria.request_dispatch(request(%{id: Ecto.UUID.generate()}, event!(tenant)))

      assert {:error, :invalid_request} =
               Mensageria.request_dispatch(request(tenant, event!(tenant), %{recipient: "123"}))

      assert {:error, :invalid_request} = Mensageria.request_dispatch(nil)

      refute_enqueued(worker: DispatchWorker)
      assert balance(tenant) == 5
      assert Mensageria.list_message_logs(tenant.id) == []
    end

    test "log, debit, ledger entry and job are one unit: undoing it undoes all four" do
      tenant = tenant!(5)

      assert {:error, :abort} =
               Repo.transaction(fn ->
                 assert {:ok, _log} = Mensageria.request_dispatch(request(tenant, event!(tenant)))
                 assert balance(tenant) == 4
                 assert [_job] = all_enqueued(worker: DispatchWorker)

                 Repo.rollback(:abort)
               end)

      assert balance(tenant) == 5
      assert Mensageria.list_message_logs(tenant.id) == []
      assert ledger_count(tenant.id) == 1
      refute_enqueued(worker: DispatchWorker)
    end
  end

  describe "idempotency (AC-3)" do
    test "a repeated request is a duplicate and leaves a single job" do
      tenant = tenant!(5)
      event = event!(tenant)

      assert {:ok, log} = Mensageria.request_dispatch(request(tenant, event))
      assert {:duplicate, same} = Mensageria.request_dispatch(request(tenant, event))

      assert same.id == log.id
      assert balance(tenant) == 4
      assert [_only_job] = all_enqueued(worker: DispatchWorker)
    end

    test "reserve/1 alone enqueues nothing" do
      tenant = tenant!(5)

      assert {:ok, _log} = Mensageria.reserve(request(tenant, event!(tenant)))

      refute_enqueued(worker: DispatchWorker)
    end

    test "different events each get their own job" do
      tenant = tenant!(5)

      {:ok, _} = Mensageria.request_dispatch(request(tenant, event!(tenant)))
      {:ok, _} = Mensageria.request_dispatch(request(tenant, event!(tenant)))

      assert length(all_enqueued(worker: DispatchWorker)) == 2
    end
  end

  test "the enqueued job runs the dispatch end to end" do
    tenant = tenant!(5)
    {:ok, log} = Mensageria.request_dispatch(request(tenant, event!(tenant)))

    assert [job] = all_enqueued(worker: DispatchWorker)
    assert :ok = perform_job(DispatchWorker, job.args)

    assert %MessageLog{status: "sent"} = Mensageria.get_message_log(tenant.id, log.id)
    assert balance(tenant) == 4
  end
end
