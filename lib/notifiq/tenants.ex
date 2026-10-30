defmodule Notifiq.Tenants do
  @moduledoc """
  Tenants and their connections to external accounts (Specs 006 and 008). Balance
  changes are not here: they go through `Notifiq.Mensageria` so each one has a ledger
  entry.

  Every function takes the `tenant_id` and filters by it, with one deliberate exception:
  `resolve_tenant/2`, which is how the tenant of an incoming webhook is *determined*.
  """

  import Ecto.Query

  alias Notifiq.Repo
  alias Notifiq.Tenants.Integration
  alias Notifiq.Tenants.Tenant

  @spec create_tenant(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Ids of every tenant, for maintenance jobs that sweep tenant by tenant."
  @spec list_tenant_ids() :: [Ecto.UUID.t()]
  def list_tenant_ids, do: Repo.all(from t in Tenant, select: t.id)

  @spec get_tenant(Ecto.UUID.t()) :: Tenant.t() | nil
  def get_tenant(id), do: Repo.get(Tenant, id)

  # --- integrations (Spec 008) -----------------------------------------------------

  @doc """
  Connects the tenant to an account of a registered source. `attrs` takes `:source` and
  `:external_account_id`. An account can be active for one tenant at a time.
  """
  @spec connect_integration(Ecto.UUID.t(), map()) ::
          {:ok, Integration.t()} | {:error, Ecto.Changeset.t()}
  def connect_integration(tenant_id, attrs) do
    %Integration{tenant_id: tenant_id}
    |> Integration.connect_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Disables the tenant's own integration, freeing the account. Never touches another tenant's."
  @spec disconnect_integration(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Integration.t()} | {:error, :not_found}
  def disconnect_integration(tenant_id, integration_id) do
    query =
      from i in Integration,
        where: i.id == ^integration_id and i.tenant_id == ^tenant_id,
        select: i

    case Repo.update_all(query, set: [status: "disabled", updated_at: DateTime.utc_now()]) do
      {1, [%Integration{} = integration]} -> {:ok, integration}
      {0, _} -> {:error, :not_found}
    end
  end

  @spec get_integration(Ecto.UUID.t(), Ecto.UUID.t()) :: Integration.t() | nil
  def get_integration(tenant_id, id) do
    Repo.one(from i in Integration, where: i.tenant_id == ^tenant_id and i.id == ^id)
  end

  @spec list_integrations(Ecto.UUID.t()) :: [Integration.t()]
  def list_integrations(tenant_id) do
    Repo.all(
      from i in Integration,
        where: i.tenant_id == ^tenant_id,
        order_by: [asc: i.inserted_at, asc: i.id]
    )
  end

  @doc """
  The tenant that currently owns `external_account_id` of `source`.

  This is the one lookup that is not scoped by tenant, because it is what decides the
  tenant. It must only run for requests whose authenticity was already verified.
  """
  @spec resolve_tenant(String.t(), String.t()) :: {:ok, Ecto.UUID.t()} | :error
  def resolve_tenant(source, external_account_id)
      when is_binary(source) and is_binary(external_account_id) do
    query =
      from i in Integration,
        where:
          i.source == ^source and i.external_account_id == ^external_account_id and
            i.status == "active",
        select: i.tenant_id

    case Repo.one(query) do
      nil -> :error
      tenant_id -> {:ok, tenant_id}
    end
  end

  def resolve_tenant(_source, _external_account_id), do: :error
end
