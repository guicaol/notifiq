defmodule Notifiq.Mensageria.EventWorkerTest do
  use Notifiq.DataCase, async: true
  use Oban.Testing, repo: Notifiq.Repo

  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.WebhookEvent

  test "performs for a stored event" do
    now = DateTime.utc_now()

    event =
      Repo.insert!(%WebhookEvent{
        source: "fake",
        external_event_id: "evt-1",
        event_type: "order_created",
        payload: %{},
        inserted_at: now,
        updated_at: now
      })

    assert :ok = perform_job(EventWorker, %{webhook_event_id: event.id})
  end

  test "discards the job when the event no longer exists" do
    assert {:discard, :webhook_event_not_found} =
             perform_job(EventWorker, %{webhook_event_id: Ecto.UUID.generate()})
  end
end
