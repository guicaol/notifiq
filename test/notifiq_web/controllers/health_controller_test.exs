defmodule NotifiqWeb.HealthControllerTest do
  # async: false because the degraded scenario swaps the health check
  # implementation via global application env.
  use NotifiqWeb.ConnCase, async: false

  defmodule UnreachableDatabase do
    @behaviour Notifiq.Health

    @impl true
    def database_status, do: {:error, :database_unreachable}
  end

  describe "GET /health" do
    # AC-2
    test "returns 200 with status ok when the database is reachable", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    # AC-3 / FR-2 — simulated via stub, without stopping the real PostgreSQL
    test "returns 503 with degraded body when the database is unreachable", %{conn: conn} do
      Application.put_env(:notifiq, :health_database_check, UnreachableDatabase)
      on_exit(fn -> Application.delete_env(:notifiq, :health_database_check) end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{
               "status" => "degraded",
               "reason" => "database_unreachable"
             }
    end
  end
end
