defmodule NotifiqWeb.HealthController do
  use NotifiqWeb, :controller

  def show(conn, _params) do
    case Notifiq.Health.database_status() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, :database_unreachable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "degraded", reason: "database_unreachable"})
    end
  end
end
