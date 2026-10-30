defmodule Notifiq.Mensageria.ReserveTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.CreditTransaction
  alias Notifiq.Mensageria.MessageLog

  describe "reserve/1 with enough credits (AC-1)" do
    test "creates the pending log, debits the cost and writes the ledger entry" do
      tenant = tenant!(5)
      event = event!(tenant)

      assert {:ok, %MessageLog{} = log} = Mensageria.reserve(reservation(tenant, event))

      assert log.status == "pending"
      assert log.attempts == 0
      assert log.tenant_id == tenant.id
      assert log.webhook_event_id == event.id
      assert log.provider == "fake_sms"
      assert log.channel == "sms"
      assert log.recipient == "+5511999998888"
      assert log.cost == 1

      assert balance(tenant) == 4

      assert [%CreditTransaction{} = entry | _] = Mensageria.list_credit_transactions(tenant.id)
      assert entry.amount == -1
      assert entry.reason == "dispatch"
      assert entry.message_log_id == log.id

      assert_invariant!(tenant.id)
    end

    test "charges the informed cost and accepts a string channel" do
      tenant = tenant!(5)
      attrs = reservation(tenant, event!(tenant), %{cost: 3, channel: "sms"})

      assert {:ok, %MessageLog{cost: 3, channel: "sms"}} = Mensageria.reserve(attrs)
      assert balance(tenant) == 2
      assert_invariant!(tenant.id)
    end

    test "spends the last credit" do
      tenant = tenant!(1)

      assert {:ok, _log} = Mensageria.reserve(reservation(tenant, event!(tenant)))
      assert balance(tenant) == 0
    end
  end

  describe "insufficient credits (AC-2)" do
    test "creates nothing and leaves the balance untouched" do
      tenant = tenant!(1)

      assert {:error, :insufficient_credits} =
               Mensageria.reserve(reservation(tenant, event!(tenant), %{cost: 2}))

      assert balance(tenant) == 1
      assert Mensageria.list_message_logs(tenant.id) == []
      assert ledger_count(tenant.id) == 1
      assert_invariant!(tenant.id)
    end

    test "a tenant with no credits at all cannot reserve" do
      tenant = tenant!(0)

      assert {:error, :insufficient_credits} =
               Mensageria.reserve(reservation(tenant, event!(tenant)))

      assert Mensageria.list_message_logs(tenant.id) == []
    end

    test "the database refuses a negative balance whatever the code does" do
      tenant = tenant!(1)

      assert_raise Postgrex.Error, ~r/credit_balance_non_negative/, fn ->
        Repo.query!("UPDATE tenants SET credit_balance = -1 WHERE id = $1", [
          Ecto.UUID.dump!(tenant.id)
        ])
      end
    end
  end

  describe "idempotency (AC-3)" do
    test "a second reservation of the same event is a duplicate and charges nothing" do
      tenant = tenant!(5)
      event = event!(tenant)

      assert {:ok, log} = Mensageria.reserve(reservation(tenant, event))
      assert {:duplicate, same} = Mensageria.reserve(reservation(tenant, event))

      assert same.id == log.id
      assert balance(tenant) == 4
      assert length(Mensageria.list_message_logs(tenant.id)) == 1
      assert_invariant!(tenant.id)
    end

    test "a duplicate is reported even when the tenant has no credits left" do
      tenant = tenant!(1)
      event = event!(tenant)

      {:ok, log} = Mensageria.reserve(reservation(tenant, event))
      assert balance(tenant) == 0

      assert {:duplicate, %MessageLog{id: id}} = Mensageria.reserve(reservation(tenant, event))
      assert id == log.id
    end

    test "different events are independent reservations" do
      tenant = tenant!(5)

      assert {:ok, _} = Mensageria.reserve(reservation(tenant, event!(tenant)))
      assert {:ok, _} = Mensageria.reserve(reservation(tenant, event!(tenant)))
      assert balance(tenant) == 3
    end

    test "the database allows only one log per event" do
      tenant = tenant!(5)
      log = reserve!(tenant)
      now = DateTime.utc_now()

      row = %{
        id: Ecto.UUID.generate(),
        tenant_id: tenant.id,
        webhook_event_id: log.webhook_event_id,
        provider: "fake_sms",
        channel: "sms",
        recipient: "+5511999998888",
        body: "x",
        inserted_at: now,
        updated_at: now
      }

      assert_raise Postgrex.Error, ~r/message_logs_webhook_event_id_index/, fn ->
        Repo.insert_all(MessageLog, [row])
      end
    end
  end

  describe "references (AC-6)" do
    test "an unknown event is refused with no effects" do
      tenant = tenant!(5)
      attrs = reservation(tenant, event!(tenant), %{webhook_event_id: Ecto.UUID.generate()})

      assert {:error, :unknown_event} = Mensageria.reserve(attrs)
      assert balance(tenant) == 5
      assert Mensageria.list_message_logs(tenant.id) == []
    end

    test "an unknown tenant is refused with no effects" do
      event = event!(tenant!(1))
      attrs = reservation(%{id: Ecto.UUID.generate()}, event)

      assert {:error, :unknown_tenant} = Mensageria.reserve(attrs)
      refute Repo.get_by(MessageLog, webhook_event_id: event.id)
    end
  end

  describe "request validation (AC-7)" do
    setup do
      tenant = tenant!(5)
      %{tenant: tenant, event: event!(tenant)}
    end

    test "rejects malformed requests without touching the balance", %{
      tenant: tenant,
      event: event
    } do
      invalid = [
        %{recipient: "11999998888"},
        %{recipient: nil},
        %{body: ""},
        %{body: nil},
        %{channel: :email},
        %{channel: "pigeon"},
        %{channel: nil},
        %{provider: ""},
        %{provider: nil},
        %{cost: 0},
        %{cost: -1},
        %{cost: 1.5},
        %{tenant_id: "not-a-uuid"},
        %{tenant_id: nil},
        %{webhook_event_id: "not-a-uuid"}
      ]

      for overrides <- invalid do
        assert {:error, :invalid_request} =
                 Mensageria.reserve(reservation(tenant, event, overrides)),
               inspect(overrides)
      end

      assert {:error, :invalid_request} = Mensageria.reserve(%{})
      assert {:error, :invalid_request} = Mensageria.reserve(nil)
      assert balance(tenant) == 5
      assert Mensageria.list_message_logs(tenant.id) == []
    end

    test "never creates atoms from the channel input", %{tenant: tenant, event: event} do
      name = "channel_#{System.unique_integer([:positive])}"

      assert {:error, :invalid_request} =
               Mensageria.reserve(reservation(tenant, event, %{channel: name}))

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end
end
