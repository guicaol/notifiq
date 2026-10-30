defmodule Notifiq.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :credit_balance, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # Constitution principle 5: the balance can never go negative, whatever the code does.
    create constraint(:tenants, :credit_balance_non_negative, check: "credit_balance >= 0")
  end
end
