defmodule Notifiq.Mensageria.TenantIsolationTest do
  # Constitution, principle 7: a tenant never sees or touches another tenant's data.
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria

  setup do
    tenant_a = tenant!(5, "Tenant A")
    tenant_b = tenant!(5, "Tenant B")
    log_a = reserve!(tenant_a)

    %{a: tenant_a, b: tenant_b, log_a: log_a}
  end

  test "AC-13: reads are scoped by tenant", %{a: a, b: b, log_a: log_a} do
    assert Mensageria.get_message_log(a.id, log_a.id).id == log_a.id
    assert Mensageria.get_message_log(b.id, log_a.id) == nil

    assert [%{id: id}] = Mensageria.list_message_logs(a.id)
    assert id == log_a.id
    assert Mensageria.list_message_logs(b.id) == []

    assert Enum.all?(Mensageria.list_credit_transactions(a.id), &(&1.tenant_id == a.id))
    assert Enum.all?(Mensageria.list_credit_transactions(b.id), &(&1.tenant_id == b.id))
    refute Enum.any?(Mensageria.list_credit_transactions(b.id), &(&1.message_log_id == log_a.id))
  end

  test "B cannot record an outcome on A's log, even holding the struct", %{
    a: a,
    b: b,
    log_a: log_a
  } do
    forged = %{log_a | tenant_id: b.id}

    assert {:error, :not_found} =
             Mensageria.record_outcome(forged, {:error, {:permanent, :invalid_number}})

    assert Mensageria.get_message_log(a.id, log_a.id).status == "pending"
    assert balance(a) == 4
    assert balance(b) == 5
  end

  test "B cannot give up on A's log or earn A's refund", %{a: a, b: b, log_a: log_a} do
    assert {:error, :not_found} = Mensageria.give_up(%{log_a | tenant_id: b.id}, :x)

    assert Mensageria.get_message_log(a.id, log_a.id).status == "pending"
    assert balance(a) == 4
    assert balance(b) == 5
    assert_invariant!(a.id)
    assert_invariant!(b.id)
  end

  test "B cannot make A's log send", %{a: a, b: b, log_a: log_a} do
    assert {:error, :not_found} = Mensageria.attempt_dispatch(b.id, log_a.id)

    assert Mensageria.get_message_log(a.id, log_a.id).attempts == 0
  end

  test "B reserving A's event is refused as if it didn't exist, and charges nothing",
       %{a: a, b: b, log_a: log_a} do
    attrs = reservation(b, %{id: log_a.webhook_event_id})

    assert {:error, :unknown_event} = Mensageria.reserve(attrs)
    assert {:error, :unknown_event} = Mensageria.request_dispatch(attrs)

    assert balance(b) == 5
    assert Mensageria.list_message_logs(b.id) == []
    assert balance(a) == 4
  end

  test "debits, refunds and purchases move only their own tenant's balance", %{a: a, b: b} do
    log_b = reserve!(b)
    assert balance(b) == 4

    {:ok, _} = Mensageria.record_outcome(log_b, {:error, {:permanent, :x}})
    {:ok, _} = Mensageria.add_credits(a.id, 10)

    assert balance(a) == 14
    assert balance(b) == 5
    assert_invariant!(a.id)
    assert_invariant!(b.id)
  end

  test "the balance read of a missing tenant is nil, not another tenant's" do
    assert Mensageria.credit_balance(Ecto.UUID.generate()) == nil
  end

  describe "received events (Spec 008, AC-10)" do
    test "a tenant reads only its own events", %{a: a, b: b} do
      event_a = event!(a)
      event_b = event!(b)

      # A already owns the event behind `log_a` from the setup, so compare membership.
      ids_a = a.id |> Mensageria.list_webhook_events() |> Enum.map(& &1.id)
      ids_b = b.id |> Mensageria.list_webhook_events() |> Enum.map(& &1.id)

      assert event_a.id in ids_a
      assert ids_b == [event_b.id]
      refute event_b.id in ids_a
      refute event_a.id in ids_b

      assert Mensageria.get_webhook_event(a.id, event_a.id)
      assert Mensageria.get_webhook_event(b.id, event_a.id) == nil
      assert Mensageria.get_webhook_event(a.id, Ecto.UUID.generate()) == nil
    end

    test "AC-9: a tenant can't reserve or dispatch an event that isn't its own",
         %{a: a, b: b} do
      foreign = event!(a)
      before = balance(b)

      assert {:error, :unknown_event} = Mensageria.reserve(reservation(b, foreign))
      assert {:error, :unknown_event} = Mensageria.request_dispatch(reservation(b, foreign))

      assert balance(b) == before
      assert Mensageria.list_message_logs(b.id) == []
      assert Mensageria.list_message_logs(a.id) |> Enum.all?(&(&1.webhook_event_id != foreign.id))
    end

    test "the owner can still reserve its own event", %{a: a} do
      assert {:ok, _log} = Mensageria.reserve(reservation(a, event!(a)))
    end
  end
end
