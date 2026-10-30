defmodule Notifiq.Tenants.Integration do
  @moduledoc """
  A tenant's connection to an account of an external source (Spec 008). It is how an
  incoming webhook is attributed to a tenant: the source says which of *its* accounts the
  event came from, and the active integration for that account names the tenant.

  It stores no secrets: verification credentials are per source for now, and per-tenant
  tokens will need encryption (Constitution, principle 6) when the OAuth spec adds them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Notifiq.Integrations.Registry

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t(),
          source: String.t(),
          external_account_id: String.t(),
          status: String.t()
        }

  schema "integrations" do
    field :tenant_id, :binary_id
    field :source, :string
    field :external_account_id, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for connecting an account. `tenant_id` is set by the caller on the struct,
  never cast from params.
  """
  def connect_changeset(%__MODULE__{} = integration, attrs) do
    integration
    |> cast(attrs, [:source, :external_account_id])
    |> update_change(:external_account_id, &String.trim/1)
    |> validate_required([:source, :external_account_id])
    |> validate_length(:external_account_id, max: 255)
    |> validate_change(:source, fn :source, source ->
      case Registry.fetch(source) do
        {:ok, _adapter} -> []
        :error -> [source: "is not a registered source"]
      end
    end)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint(:external_account_id,
      name: :integrations_active_account_index,
      message: "is already connected"
    )
  end
end
