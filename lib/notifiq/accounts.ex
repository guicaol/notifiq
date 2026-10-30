defmodule Notifiq.Accounts do
  @moduledoc """
  Users of the panel and their sessions (Spec 010).

  There is no public sign-up: accounts are created by the operator
  (`mix notifiq.create_account`). Nothing here takes a `tenant_id` from a request; the
  tenant of a signed-in user is the one stored on the user, and the web layer reads it
  from `Notifiq.Accounts.Scope`.

  Two lookups are deliberately not filtered by tenant, because they are how the tenant
  gets *determined* at the door: `get_user_by_email_and_password/2` and
  `get_user_by_session_token/1`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Notifiq.Accounts.User
  alias Notifiq.Accounts.UserToken
  alias Notifiq.Repo
  alias Notifiq.Tenants.Tenant

  @doc """
  Creates a tenant and its first user in one transaction. `attrs` takes `:tenant_name`,
  `:email` and `:password`; if the user is invalid no tenant is left behind.
  """
  @spec create_account(map()) ::
          {:ok, %{tenant: Tenant.t(), user: User.t()}} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Multi.new()
    |> Multi.insert(:tenant, Tenant.changeset(%Tenant{}, %{"name" => attrs["tenant_name"]}))
    |> Multi.insert(:user, fn %{tenant: tenant} ->
      User.registration_changeset(%User{tenant_id: tenant.id}, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tenant: tenant, user: user}} -> {:ok, %{tenant: tenant, user: user}}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  The user with this email and password, or `nil`. An unknown email costs the same hashing
  work as a wrong password, so the response time doesn't reveal which accounts exist.
  """
  @spec get_user_by_email_and_password(term(), term()) :: User.t() | nil
  def get_user_by_email_and_password(email, password) do
    email = User.normalize_email(email)
    user = email && Repo.get_by(User, email: email)

    if user && User.valid_password_length?(password) do
      if Pbkdf2.verify_pass(password, user.hashed_password), do: user
    else
      Pbkdf2.no_user_verify()
      nil
    end
  end

  @doc "Replaces the user's password and revokes every session they have."
  @spec reset_password(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_password(%User{} = user, password) do
    changeset = User.password_changeset(user, %{password: password})

    Multi.new()
    |> Multi.update(:user, changeset)
    |> Multi.delete_all(:tokens, UserToken.by_user_query(user.id))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "The user that currently owns `email`, mainly for operator tasks."
  @spec get_user_by_email(term()) :: User.t() | nil
  def get_user_by_email(email) do
    case User.normalize_email(email) do
      nil -> nil
      email -> Repo.get_by(User, email: email)
    end
  end

  # --- sessions ---------------------------------------------------------------------

  @doc "Starts a session for `user`; returns the raw token to give the browser."
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(%User{} = user) do
    {token, row} = UserToken.build_session_token(user)
    Repo.insert!(row)
    token
  end

  @doc "The user a session token belongs to, or `nil` when it is unknown, forged or expired."
  @spec get_user_by_session_token(term()) :: User.t() | nil
  def get_user_by_session_token(token) when is_binary(token),
    do: token |> UserToken.verify_session_token_query() |> Repo.one()

  def get_user_by_session_token(_token), do: nil

  @doc "Ends one session."
  @spec delete_user_session_token(term()) :: :ok
  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  def delete_user_session_token(_token), do: :ok

  @doc "How many sessions the user has (for tests and operators)."
  @spec count_sessions(User.t()) :: non_neg_integer()
  def count_sessions(%User{id: user_id}),
    do: Repo.aggregate(from(t in UserToken, where: t.user_id == ^user_id), :count)
end
