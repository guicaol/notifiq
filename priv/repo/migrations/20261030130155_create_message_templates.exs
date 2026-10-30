defmodule Notifiq.Repo.Migrations.CreateMessageTemplates do
  use Ecto.Migration

  def change do
    create table(:message_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false
      add :event_type, :string, null: false
      add :channel, :string, null: false
      add :provider, :string, null: false
      add :body, :text, null: false
      add :cost, :integer, null: false, default: 1
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:message_templates, [:tenant_id])

    # A received event produces one dispatch (Spec 006), so a tenant has one active
    # template per event type: it names the channel, the provider and the text.
    create unique_index(:message_templates, [:tenant_id, :event_type],
             where: "active",
             name: :message_templates_active_event_type_index
           )

    create constraint(:message_templates, :cost_between_1_and_10, check: "cost BETWEEN 1 AND 10")
  end
end
