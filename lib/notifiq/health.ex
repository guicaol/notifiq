defmodule Notifiq.Health do
  @moduledoc """
  Application health checks (Spec 001).

  The database check is performed per call — never cached — so the
  `/health` endpoint always reflects the current connectivity state.
  The concrete implementation is swappable through the
  `:health_database_check` application env, allowing tests to simulate
  an unreachable database without stopping the real PostgreSQL.
  """

  @callback database_status() :: :ok | {:error, :database_unreachable}

  @spec database_status() :: :ok | {:error, :database_unreachable}
  def database_status, do: impl().database_status()

  defp impl do
    Application.get_env(:notifiq, :health_database_check, __MODULE__.Database)
  end
end
