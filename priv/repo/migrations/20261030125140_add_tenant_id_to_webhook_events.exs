defmodule Notifiq.Repo.Migrations.AddTenantIdToWebhookEvents do
  use Ecto.Migration

  def up do
    alter table(:webhook_events) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict)
    end

    # Deliberately loud: if events without a tenant exist this fails instead of deleting
    # or guessing an owner for them.
    execute "ALTER TABLE webhook_events ALTER COLUMN tenant_id SET NOT NULL"

    create index(:webhook_events, [:tenant_id, :inserted_at])
  end

  def down do
    drop index(:webhook_events, [:tenant_id, :inserted_at])

    alter table(:webhook_events) do
      remove :tenant_id
    end
  end
end
