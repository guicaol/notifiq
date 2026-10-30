defmodule Notifiq.Health.Database do
  @moduledoc false
  @behaviour Notifiq.Health

  @impl true
  def database_status do
    case Notifiq.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :database_unreachable}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :database_unreachable}
  catch
    :exit, _reason -> {:error, :database_unreachable}
  end
end
