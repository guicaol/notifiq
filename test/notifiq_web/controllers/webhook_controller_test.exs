defmodule NotifiqWeb.WebhookControllerTest do
  # Not async: the idempotency/load tests share one sandbox connection across tasks.
  use NotifiqWeb.ConnCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import ExUnit.CaptureLog

  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo

  @payload %{"id" => "evt-1", "name" => "Maria", "order" => "100"}

  defp webhook_path(source_key), do: "/api/webhooks/#{source_key}"
  defp event_count, do: Repo.aggregate(WebhookEvent, :count)

  describe "routing (FR-1, FR-2)" do
    test "AC-1: routes to the registered adapter and enqueues one job", %{conn: conn} do
      conn = post(conn, webhook_path("fake"), @payload)

      assert json_response(conn, 200) == %{"status" => "accepted"}

      assert %WebhookEvent{id: id, source: "fake", event_type: "order_created"} =
               Repo.one!(WebhookEvent)

      assert_enqueued(worker: EventWorker, args: %{webhook_event_id: id})
    end

    test "AC-2: unknown source returns 404 and stores nothing", %{conn: conn} do
      conn = post(conn, webhook_path("inexistente"), @payload)

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert event_count() == 0
      refute_enqueued(worker: EventWorker)
    end

    test "source keys are case sensitive", %{conn: conn} do
      assert json_response(post(conn, webhook_path("Fake"), @payload), 404)
    end

    test "the adapter only sees the body, never the path params", %{conn: conn} do
      post(conn, webhook_path("fake"), @payload)

      assert %WebhookEvent{payload: %{"raw" => raw}} = Repo.one!(WebhookEvent)
      assert raw == @payload
    end
  end

  describe "authenticity (FR-3, FR-4)" do
    test "AC-3: invalid signature returns 401 with no event and no job", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-fake-signature", "invalid")
        |> post(webhook_path("fake"), @payload)

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert event_count() == 0
      refute_enqueued(worker: EventWorker)
    end

    test "a verify callback slower than the timeout fails the request without hanging",
         %{conn: conn} do
      log =
        capture_log(fn ->
          conn =
            conn
            |> put_req_header("x-fake-sleep", "5000")
            |> post(webhook_path("fake"), @payload)

          assert json_response(conn, 500) == %{"error" => "internal_error"}
        end)

      assert log =~ "timed out source_key=fake"
      assert event_count() == 0
    end
  end

  describe "parsing (FR-5, FR-6, FR-12)" do
    test "AC-5: {:ok, :ignore} returns 200 and creates nothing", %{conn: conn} do
      conn = post(conn, webhook_path("fake"), %{"id" => "evt-ignored", "type" => "ignore"})

      assert json_response(conn, 200) == %{"status" => "ignored"}
      assert event_count() == 0
      refute_enqueued(worker: EventWorker)
    end

    test "{:error, reason} from parse/1 is acknowledged (2xx) but creates nothing", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = post(conn, webhook_path("fake"), %{"id" => "evt-bad", "type" => "invalid"})

          assert json_response(conn, 200) == %{
                   "status" => "rejected",
                   "reason" => "invalid_phone"
                 }
        end)

      assert log =~ "webhook event rejected source_key=fake reason=invalid_phone"
      assert event_count() == 0
      refute_enqueued(worker: EventWorker)
    end

    test "AC-7: an exception in parse/1 returns 500, logs the source_key and isolates other sources",
         %{conn: conn} do
      log =
        capture_log(fn ->
          conn = post(conn, webhook_path("fake"), %{"id" => "evt-boom", "type" => "raise"})
          assert json_response(conn, 500) == %{"error" => "internal_error"}
        end)

      assert log =~ "integration callback raised source_key=fake callback=parse"
      assert log =~ "boom from fake adapter"

      other = post(build_conn(), webhook_path("other_fake"), %{"id" => "evt-ok"})
      assert json_response(other, 200) == %{"status" => "accepted"}
    end
  end

  describe "idempotency (FR-7, FR-8)" do
    test "a sequential redelivery is a duplicate and enqueues no second job", %{conn: conn} do
      assert json_response(post(conn, webhook_path("fake"), @payload), 200) == %{
               "status" => "accepted"
             }

      assert json_response(post(build_conn(), webhook_path("fake"), @payload), 200) ==
               %{"status" => "duplicate"}

      assert event_count() == 1
      assert [_one_job] = all_enqueued(worker: EventWorker)
    end

    test "the same event id from different sources is not a duplicate", %{conn: conn} do
      post(conn, webhook_path("fake"), %{"id" => "same"})
      post(build_conn(), webhook_path("other_fake"), %{"id" => "same"})

      assert event_count() == 2
      assert length(all_enqueued(worker: EventWorker)) == 2
    end

    test "the database itself rejects a duplicate (source, external_event_id)" do
      row = fn ->
        now = DateTime.utc_now()

        %{
          id: Ecto.UUID.generate(),
          source: "fake",
          external_event_id: "dup",
          event_type: "order_created",
          status: "received",
          payload: %{},
          inserted_at: now,
          updated_at: now
        }
      end

      assert {1, _} = Repo.insert_all(WebhookEvent, [row.()])

      assert_raise Postgrex.Error, ~r/webhook_events_source_external_event_id_index/, fn ->
        Repo.insert_all(WebhookEvent, [row.()])
      end
    end

    test "AC-4: parallel deliveries of the same event enqueue exactly one job" do
      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            build_conn() |> post(webhook_path("fake"), @payload) |> json_response(200)
          end)
        end)
        |> Task.await_many(10_000)

      statuses = Enum.map(results, & &1["status"])
      assert Enum.count(statuses, &(&1 == "accepted")) == 1
      assert Enum.count(statuses, &(&1 == "duplicate")) == 9
      assert event_count() == 1
      assert [_one_job] = all_enqueued(worker: EventWorker)
    end
  end

  describe "request body" do
    test "invalid JSON returns 400 and creates nothing", %{conn: conn} do
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(webhook_path("fake"), "{not json")
      end

      assert event_count() == 0
    end

    test "a body without a JSON content type returns 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(webhook_path("fake"), "hello")

      assert json_response(conn, 400) == %{"error" => "invalid_body"}
    end
  end

  describe "latency (FR-9)" do
    test "AC-8: p95 stays under 200ms with 50 concurrent requests" do
      timings =
        1..50
        |> Enum.map(fn n ->
          Task.async(fn ->
            {micros, conn} =
              :timer.tc(fn ->
                post(build_conn(), webhook_path("fake"), %{"id" => "load-#{n}"})
              end)

            assert json_response(conn, 200)
            micros
          end)
        end)
        |> Task.await_many(30_000)
        |> Enum.sort()

      p95 = Enum.at(timings, ceil(length(timings) * 0.95) - 1)

      assert p95 < 200_000, "p95 was #{div(p95, 1000)}ms"
      assert event_count() == 50
      # Heavy work is deferred: the jobs are only enqueued, never run inline.
      assert length(all_enqueued(worker: EventWorker)) == 50
    end
  end
end
