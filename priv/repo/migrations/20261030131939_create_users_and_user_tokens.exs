defmodule Notifiq.Repo.Migrations.CreateUsersAndUserTokens do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false
      add :email, :string, null: false
      add :hashed_password, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:users, [:tenant_id])

    # Emails are stored lowercased (Notifiq.Accounts.User), so a plain unique index is
    # already case-insensitive; the check keeps a direct insert from breaking that.
    create unique_index(:users, [:email])
    create constraint(:users, :email_lowercase, check: "email = lower(email)")

    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # SHA-256 of the token the browser holds; the token itself is never stored.
      add :token, :binary, null: false
      add :context, :string, null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])
  end
end
