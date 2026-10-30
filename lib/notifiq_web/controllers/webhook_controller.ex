defmodule NotifiqWeb.WebhookController do
  @moduledoc """
  Generic webhook endpoint (Spec 002). Knows nothing about any specific source:
  all routing goes through `Notifiq.Integrations.Registry` and the work through
  `Notifiq.Integrations.Ingestion`.
  """

  use NotifiqWeb, :controller

  alias Notifiq.Integrations.Ingestion

  def create(conn, %{"source_key" => source_key}) do
    # `conn.params` mixes in the path params; the adapter must only see the body.
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        respond_error(conn, :bad_request, "invalid_body")

      payload when is_map(payload) ->
        source_key |> Ingestion.ingest(conn, payload) |> respond(conn)
    end
  end

  defp respond({:ok, status}, conn), do: json(conn, %{status: Atom.to_string(status)})
  defp respond({:error, :not_found}, conn), do: respond_error(conn, :not_found, "not_found")

  defp respond({:error, :unauthorized}, conn),
    do: respond_error(conn, :unauthorized, "unauthorized")

  # A signed event we can't use will never become usable: answer 2xx so sources that
  # retry on failures (some retry for days, then disable the webhook) stop sending.
  defp respond({:error, {:unprocessable, reason}}, conn) do
    json(conn, %{status: "rejected", reason: Atom.to_string(reason)})
  end

  defp respond({:error, :internal}, conn),
    do: respond_error(conn, :internal_server_error, "internal_error")

  defp respond_error(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
