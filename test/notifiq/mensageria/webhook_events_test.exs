defmodule Notifiq.Mensageria.WebhookEventsTest do
  # Spec 008, AC-11: the database itself refuses an event with no tenant.
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria.WebhookEvent

  defp row(overrides \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        source: "fake",
        external_event_id: "evt-#{System.unique_integer([:positive])}",
        event_type: "order_created",
        status: "received",
        payload: %{},
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  test "accepts an event that belongs to an existing tenant" do
    tenant = tenant!()

    assert {1, _} = Repo.insert_all(WebhookEvent, [row(%{tenant_id: tenant.id})])
  end

  test "refuses an event without a tenant" do
    assert_raise Postgrex.Error, ~r/not_null_violation|tenant_id/, fn ->
      Repo.insert_all(WebhookEvent, [row()])
    end
  end

  test "refuses an event whose tenant doesn't exist" do
    assert_raise Postgrex.Error, ~r/webhook_events_tenant_id_fkey/, fn ->
      Repo.insert_all(WebhookEvent, [row(%{tenant_id: Ecto.UUID.generate()})])
    end
  end

  test "a tenant that owns events can't be deleted from under them" do
    tenant = tenant!()
    event!(tenant)

    assert_raise Postgrex.Error, ~r/foreign_key_violation|webhook_events_tenant_id_fkey/, fn ->
      Repo.query!("DELETE FROM tenants WHERE id = $1", [Ecto.UUID.dump!(tenant.id)])
    end
  end
end
