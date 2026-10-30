defmodule Notifiq.Repo.Migrations.CreateWebhookEvents do
  use Ecto.Migration

  def change do
    create table(:webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source, :string, null: false
      add :external_event_id, :string, null: false
      add :event_type, :string, null: false
      add :status, :string, null: false, default: "received"
      # CanonicalEvent serialised as a map (Spec 002, canonical_event.schema.json).
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Constitution principle 4: idempotency is enforced by the database, not by
    # an in-memory check, so parallel deliveries of the same event cannot both win.
    create unique_index(:webhook_events, [:source, :external_event_id])
  end
end
