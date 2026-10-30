defmodule NotifiqWeb.BlingWebhookTest do
  # End to end through the endpoint: real body parsing, raw body caching, signature.
  use NotifiqWeb.ConnCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import ExUnit.CaptureLog

  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo
  alias Notifiq.Test.BlingHelpers

  @path "/api/webhooks/bling"

  defp deliver(conn, body, signature \\ nil) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-bling-signature-256", signature || BlingHelpers.sign(body))
    |> post(@path, body)
  end

  defp body(payload \\ BlingHelpers.sample_payload()), do: Jason.encode!(payload)

  test "a correctly signed order event is stored and enqueued", %{conn: conn} do
    conn = deliver(conn, body())

    assert json_response(conn, 200) == %{"status" => "accepted"}

    assert %WebhookEvent{id: id, source: "bling", event_type: "order_invoiced"} =
             Repo.one!(WebhookEvent)

    assert_enqueued(worker: EventWorker, args: %{webhook_event_id: id})
  end

  test "signs the exact bytes received, whatever the JSON formatting", %{conn: conn} do
    pretty = Jason.encode!(BlingHelpers.sample_payload(), pretty: true)

    assert json_response(deliver(conn, pretty), 200) == %{"status" => "accepted"}
  end

  test "Bling's retry of the same eventId is acknowledged without a second job", %{conn: conn} do
    assert json_response(deliver(conn, body()), 200) == %{"status" => "accepted"}
    assert json_response(deliver(build_conn(), body()), 200) == %{"status" => "duplicate"}

    assert Repo.aggregate(WebhookEvent, :count) == 1
    assert [_one_job] = all_enqueued(worker: EventWorker)
  end

  test "a wrong signature returns 401 and stores nothing", %{conn: conn} do
    conn = deliver(conn, body(), BlingHelpers.sign(body(), "wrong-secret"))

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert Repo.aggregate(WebhookEvent, :count) == 0
    refute_enqueued(worker: EventWorker)
  end

  test "a body altered after signing returns 401", %{conn: conn} do
    signature = BlingHelpers.sign(body())
    tampered = body(put_in(BlingHelpers.sample_payload(), ["data", "numero"], 9999))

    assert json_response(deliver(conn, tampered, signature), 401)
    assert Repo.aggregate(WebhookEvent, :count) == 0
  end

  test "a request without a signature returns 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, body())

    assert json_response(conn, 401)
  end

  test "an unmapped situation is acknowledged and ignored", %{conn: conn} do
    payload = put_in(BlingHelpers.sample_payload(), ["data", "situacao", "id"], 999)

    capture_log(fn ->
      assert json_response(deliver(conn, body(payload)), 200) == %{"status" => "ignored"}
    end)

    assert Repo.aggregate(WebhookEvent, :count) == 0
    refute_enqueued(worker: EventWorker)
  end

  test "an order with an unusable phone is acknowledged (2xx) but rejected", %{conn: conn} do
    payload = put_in(BlingHelpers.sample_payload(), ["data", "contato", "telefone"], "123")

    capture_log(fn ->
      assert json_response(deliver(conn, body(payload)), 200) ==
               %{"status" => "rejected", "reason" => "invalid_phone"}
    end)

    assert Repo.aggregate(WebhookEvent, :count) == 0
  end
end
