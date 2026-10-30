defmodule Notifiq.Test.AccountsHelpers do
  @moduledoc "Builders for panel users and sessions (Spec 010)."

  alias Notifiq.Accounts
  alias Notifiq.Accounts.User
  alias Notifiq.Repo

  @password "a long enough password"

  def password, do: @password

  @doc "A user of `tenant`; `attrs` overrides the email and password."
  def user!(tenant, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{email: "user#{System.unique_integer([:positive])}@example.com", password: @password},
        Map.new(attrs)
      )

    %User{tenant_id: tenant.id}
    |> User.registration_changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Starts a session for `user` and returns the raw token."
  def session_token!(user), do: Accounts.generate_user_session_token(user)

  @doc "Moves a session's creation back in time, to test expiry."
  def age_session!(user, days) do
    import Ecto.Query

    Repo.update_all(
      from(t in Notifiq.Accounts.UserToken, where: t.user_id == ^user.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )
  end
end
