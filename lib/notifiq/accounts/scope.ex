defmodule Notifiq.Accounts.Scope do
  @moduledoc """
  Who is acting and for which tenant (Spec 010). It is built from the authenticated
  user and is the only place the panel takes a `tenant_id` from: nothing the browser
  sends can change it.
  """

  alias Notifiq.Accounts.User
  alias Notifiq.Tenants
  alias Notifiq.Tenants.Tenant

  defstruct [:user, :tenant]

  @type t :: %__MODULE__{user: User.t(), tenant: Tenant.t()}

  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user) do
    case Tenants.get_tenant(user.tenant_id) do
      %Tenant{} = tenant -> %__MODULE__{user: user, tenant: tenant}
      nil -> nil
    end
  end

  def for_user(nil), do: nil

  @doc "The tenant every panel query is filtered by."
  @spec tenant_id(t()) :: Ecto.UUID.t()
  def tenant_id(%__MODULE__{tenant: %Tenant{id: id}}), do: id
end
