defmodule Notifiq.Accounts.UserToken do
  @moduledoc """
  Server-side half of a browser session (Spec 010). The browser holds a random token;
  this table holds only its SHA-256, so reading the database is not enough to impersonate
  anyone.
  """

  use Ecto.Schema

  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}

  @rand_size 32
  @session_validity_in_days 14
  @session "session"

  schema "user_tokens" do
    field :user_id, :binary_id
    field :token, :binary
    field :context, :string

    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end

  @doc "How long a session stays valid, counted from its creation."
  def session_validity_in_days, do: @session_validity_in_days

  @doc """
  A new session token for `user`: the raw token to give the browser and the row to
  insert (which only carries the hash).
  """
  @spec build_session_token(Notifiq.Accounts.User.t()) :: {binary(), %__MODULE__{}}
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: hash(token), context: @session, user_id: user.id}}
  end

  @doc "Query for the user a session token belongs to, if the token is known and fresh."
  def verify_session_token_query(token) when is_binary(token) do
    from t in by_token_and_context_query(token, @session),
      join: u in Notifiq.Accounts.User,
      on: u.id == t.user_id,
      where: t.inserted_at > ago(@session_validity_in_days, "day"),
      select: u
  end

  def by_token_and_context_query(token, context) when is_binary(token) do
    from t in __MODULE__, where: t.token == ^hash(token) and t.context == ^context
  end

  def by_user_query(user_id), do: from(t in __MODULE__, where: t.user_id == ^user_id)

  defp hash(token), do: :crypto.hash(:sha256, token)
end
