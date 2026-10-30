defmodule Notifiq.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    create table(:integrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false
      add :source, :string, null: false
      add :external_account_id, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:integrations, [:tenant_id])

    # One tenant owns an external account at a time; a disabled integration frees it.
    create unique_index(:integrations, [:source, :external_account_id],
             where: "status = 'active'",
             name: :integrations_active_account_index
           )

    create constraint(:integrations, :status_known, check: "status IN ('active', 'disabled')")
  end
end
