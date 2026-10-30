defmodule Notifiq.Mensageria.Sweeper do
  @moduledoc """
  Safety net for message logs a job left unfinished (Spec 007, FR-11): a job discarded
  by the Oban plugins, lost, or crashed on a node that vanished would otherwise leave the
  tenant's credit reserved forever.

  Every run it closes, with `Notifiq.Mensageria.give_up/2`, each `pending` or `uncertain`
  log that hasn't moved for `:stale_after` seconds and has no active dispatch job — a
  `pending` one is refunded, an `uncertain` one becomes `unconfirmed`.

  It works tenant by tenant, so every query stays filtered by `tenant_id` (Constitution,
  principle 7). Each run handles a bounded batch per tenant; the next run continues.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchSettings
  alias Notifiq.Tenants

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -DispatchSettings.get(:stale_after), :second)

    closed =
      Tenants.list_tenant_ids()
      |> Enum.map(&sweep_tenant(&1, cutoff))
      |> Enum.sum()

    if closed > 0, do: Logger.warning("sweeper closed #{closed} stale message log(s)")

    :ok
  end

  defp sweep_tenant(tenant_id, cutoff) do
    tenant_id
    |> Mensageria.list_stale_logs(cutoff)
    |> Enum.count(&match?({:ok, _closed}, Mensageria.give_up(&1, :stale)))
  end
end
