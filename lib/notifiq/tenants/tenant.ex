defmodule Notifiq.Tenants.Tenant do
  @moduledoc """
  A customer of the platform and the owner of a credit balance (Spec 006).

  Deliberately minimal: users, settings and isolation plumbing arrive with the
  multi-tenancy spec. `credit_balance` is never cast from params; it only changes through
  `Notifiq.Mensageria`, together with a ledger entry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          credit_balance: integer()
        }

  schema "tenants" do
    field :name, :string
    field :credit_balance, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 160)
  end
end
