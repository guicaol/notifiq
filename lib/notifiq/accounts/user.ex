defmodule Notifiq.Accounts.User do
  @moduledoc """
  A person who signs in to the panel on behalf of one tenant (Spec 010).

  `tenant_id` is set by the code that creates the user, never cast from params. The
  password only exists in memory (`:password`, redacted) until it is hashed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @min_password 12
  @max_password 128

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          hashed_password: String.t() | nil
        }

  schema "users" do
    field :tenant_id, :binary_id
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a user. The caller sets `tenant_id` on the struct."
  def registration_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password()
    |> foreign_key_constraint(:tenant_id)
  end

  @doc "Changeset for replacing the password of an existing user."
  def password_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
  end

  @doc "Lowercases and trims an email the way it is stored; `nil` for anything else."
  @spec normalize_email(term()) :: String.t() | nil
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: nil

  @doc "Whether `password` is within the length every password must respect."
  @spec valid_password_length?(term()) :: boolean()
  def valid_password_length?(password) when is_binary(password),
    do: String.length(password) <= @max_password

  def valid_password_length?(_password), do: false

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must look like name@domain")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @min_password, max: @max_password)
    |> hash_password()
  end

  # Only hashes a password that already passed validation, so a rejected one is never
  # hashed (and the hashing cost can't be forced with a huge input).
  defp hash_password(%Ecto.Changeset{valid?: true} = changeset) do
    password = get_change(changeset, :password)

    if password do
      changeset
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp hash_password(changeset), do: changeset
end
