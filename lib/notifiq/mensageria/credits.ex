defmodule Notifiq.Mensageria.Credits do
  @moduledoc """
  Balance primitives for `Notifiq.Mensageria` (Spec 006). Internal: every function takes
  the `repo` of the surrounding `Ecto.Multi` step, so the balance change and its ledger
  entry always commit or roll back together.
  """

  import Ecto.Query

  alias Notifiq.Mensageria.CreditTransaction
  alias Notifiq.Tenants.Tenant

  @doc """
  Subtracts `amount` in a single conditional `UPDATE`. The row lock it takes is held until
  the transaction ends, so concurrent debits of one tenant are serialised and the balance
  can't be overdrawn.
  """
  @spec debit(Ecto.Repo.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, :debited} | {:error, :insufficient_credits | :unknown_tenant}
  def debit(repo, tenant_id, amount) do
    query =
      from t in Tenant,
        where: t.id == ^tenant_id and t.credit_balance >= ^amount,
        update: [inc: [credit_balance: ^(-amount)]]

    case repo.update_all(query, []) do
      {1, _} ->
        {:ok, :debited}

      {0, _} ->
        if tenant_exists?(repo, tenant_id),
          do: {:error, :insufficient_credits},
          else: {:error, :unknown_tenant}
    end
  end

  @doc "Adds `amount` to the balance."
  @spec credit(Ecto.Repo.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, :credited} | {:error, :unknown_tenant}
  def credit(repo, tenant_id, amount) do
    query = from t in Tenant, where: t.id == ^tenant_id, update: [inc: [credit_balance: ^amount]]

    case repo.update_all(query, []) do
      {1, _} -> {:ok, :credited}
      {0, _} -> {:error, :unknown_tenant}
    end
  end

  @doc "Writes the ledger entry for a balance change."
  @spec record(Ecto.Repo.t(), map()) ::
          {:ok, CreditTransaction.t()} | {:error, Ecto.Changeset.t()}
  def record(repo, attrs) do
    attrs |> CreditTransaction.changeset() |> repo.insert()
  end

  @spec tenant_exists?(Ecto.Repo.t(), Ecto.UUID.t()) :: boolean()
  def tenant_exists?(repo, tenant_id),
    do: repo.exists?(from t in Tenant, where: t.id == ^tenant_id)
end
