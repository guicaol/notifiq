defmodule Notifiq.Repo.Migrations.AddSeqToCreditTransactions do
  use Ecto.Migration

  # A ledger needs an order that never ties. `inserted_at` can: two entries written in the
  # same clock tick (coarse on some systems) would otherwise be ordered by a random UUID.
  def change do
    alter table(:credit_transactions) do
      add :seq, :bigserial, null: false
    end

    create unique_index(:credit_transactions, [:seq])
  end
end
