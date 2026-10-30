defmodule Notifiq.Repo.Migrations.CreateMessageLogsAndCreditTransactions do
  use Ecto.Migration

  def change do
    create table(:message_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false

      add :webhook_event_id, references(:webhook_events, type: :binary_id, on_delete: :restrict),
        null: false

      add :provider, :string, null: false
      add :channel, :string, null: false
      add :recipient, :string, null: false
      add :body, :text, null: false
      add :cost, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :provider_message_id, :string
      add :last_error_class, :string
      add :last_error_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    # Constitution principle 4: one dispatch per received event, enforced by the database.
    create unique_index(:message_logs, [:webhook_event_id])
    create index(:message_logs, [:tenant_id, :inserted_at])
    create constraint(:message_logs, :cost_positive, check: "cost >= 1")

    create table(:credit_transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false

      add :message_log_id, references(:message_logs, type: :binary_id, on_delete: :restrict)

      add :amount, :integer, null: false
      add :reason, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:credit_transactions, [:tenant_id, :inserted_at])

    # A dispatch is debited once and refunded at most once.
    create unique_index(:credit_transactions, [:message_log_id, :reason],
             where: "message_log_id IS NOT NULL",
             name: :credit_transactions_message_log_id_reason_index
           )

    create constraint(:credit_transactions, :amount_not_zero, check: "amount <> 0")
  end
end
