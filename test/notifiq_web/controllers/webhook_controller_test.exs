defmodule NotifiqWeb.WebhookControllerTest do
  # Not async: the idempotency/load tests share one sandbox connection across tasks.
  use NotifiqWeb.ConnCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import ExUnit.CaptureLog
  import Notifiq.Test.MensageriaHelpers, only: [integration!: 3, tenant!: 2]

  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo
  alias Notifiq.Tenants

  @payload %{"id" => "evt-1", "name" => "Maria", "order" => "100"}

  defp webhook_path(source_key), do: "/api/webhooks/#{source_key}"
  defp event_count, do: Repo.aggregate(WebhookEvent, :count)

  # Every webhook is attributed to a tenant through the integration that owns its account
  # (Spec 008): without one it would be answered `unknown_account` and stored nowhere.
  setup do
    tenant = tenant!(0, "Webhook tenant")
    integration!(tenant, "fake", Notifiq.Test.FakeSource.default_account())
    integration!(tenant, "other_fake", Notifiq.Test.OtherFakeSource.default_account())

    %{tenant: tenant}
  end

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

    test "the database itself rejects a duplicate (source, external_event_id)", %{tenant: tenant} do
      row = fn ->
        now = DateTime.utc_now()

        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant.id,
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

  describe "tenant resolution (Spec 008)" do
    alias Notifiq.Mensageria

    defp accepted, do: %{"status" => "accepted"}

    test "AC-3: the event is stored under the tenant of its account, everywhere it travels",
         %{conn: conn, tenant: tenant} do
      assert json_response(post(conn, webhook_path("fake"), @payload), 200) == accepted()

      assert %WebhookEvent{id: id, tenant_id: tenant_id, payload: payload} =
               Repo.one!(WebhookEvent)

      assert tenant_id == tenant.id
      assert payload["tenant_id"] == tenant.id
      assert_enqueued(worker: EventWorker, args: %{webhook_event_id: id, tenant_id: tenant.id})
    end

    test "AC-4: two tenants with different accounts of one source each get their own events",
         %{conn: conn, tenant: a} do
      b = tenant!(0, "Tenant B")
      integration!(b, "fake", "account-b")

      post(conn, webhook_path("fake"), %{"id" => "evt-a"})
      post(build_conn(), webhook_path("fake"), %{"id" => "evt-b", "account" => "account-b"})

      assert [%{external_event_id: "evt-a"}] = Mensageria.list_webhook_events(a.id)
      assert [%{external_event_id: "evt-b"}] = Mensageria.list_webhook_events(b.id)

      assert Mensageria.get_webhook_event(a.id, hd(Mensageria.list_webhook_events(b.id)).id) ==
               nil
    end

    test "the tenant can't be chosen through the payload", %{conn: conn, tenant: a} do
      b = tenant!(0, "Tenant B")
      integration!(b, "fake", "account-b")

      payload = Map.merge(@payload, %{"tenant_id" => b.id, "tenant" => b.id, "tenantId" => b.id})
      assert json_response(post(conn, webhook_path("fake"), payload), 200) == accepted()

      assert [%{tenant_id: owner}] = Repo.all(WebhookEvent)
      assert owner == a.id
      assert Mensageria.list_webhook_events(b.id) == []
    end

    test "AC-5: an account nobody connected is acknowledged and stored nowhere", %{conn: conn} do
      Logger.put_module_level(Notifiq.Integrations.Ingestion, :info)
      on_exit(fn -> Logger.delete_module_level(Notifiq.Integrations.Ingestion) end)

      log =
        capture_log([level: :info], fn ->
          conn = post(conn, webhook_path("fake"), %{"id" => "evt-x", "account" => "nobody"})
          assert json_response(conn, 200) == %{"status" => "unknown_account"}
        end)

      assert log =~ "no active integration source_key=fake"
      refute log =~ "nobody"
      assert event_count() == 0
      refute_enqueued(worker: EventWorker)
    end

    test "AC-5: a disabled integration no longer receives events", %{conn: conn, tenant: tenant} do
      [fake | _] = Enum.filter(Tenants.list_integrations(tenant.id), &(&1.source == "fake"))
      {:ok, _} = Tenants.disconnect_integration(tenant.id, fake.id)

      assert json_response(post(conn, webhook_path("fake"), @payload), 200) ==
               %{"status" => "unknown_account"}

      assert event_count() == 0
    end

    test "after a reconnection the events go to the new owner", %{conn: conn, tenant: old_owner} do
      new_owner = tenant!(0, "New owner")
      [fake | _] = Enum.filter(Tenants.list_integrations(old_owner.id), &(&1.source == "fake"))
      {:ok, _} = Tenants.disconnect_integration(old_owner.id, fake.id)
      integration!(new_owner, "fake", Notifiq.Test.FakeSource.default_account())

      assert json_response(post(conn, webhook_path("fake"), @payload), 200) == accepted()

      assert [%{tenant_id: owner}] = Repo.all(WebhookEvent)
      assert owner == new_owner.id
      assert Mensageria.list_webhook_events(old_owner.id) == []
    end

    test "the adapter's parse isn't even called for an unknown account", %{conn: conn} do
      payload = %{"id" => "evt-x", "account" => "nobody", "type" => "raise"}

      assert json_response(post(conn, webhook_path("fake"), payload), 200) ==
               %{"status" => "unknown_account"}
    end

    test "AC-6: an invalid signature is the same 401 whether the account exists or not",
         %{conn: conn} do
      known =
        conn
        |> put_req_header("x-fake-signature", "invalid")
        |> post(webhook_path("fake"), @payload)

      unknown =
        build_conn()
        |> put_req_header("x-fake-signature", "invalid")
        |> post(webhook_path("fake"), %{"id" => "evt-x", "account" => "nobody"})

      assert json_response(known, 401) == json_response(unknown, 401)
      assert event_count() == 0
    end

    test "AC-7: a payload without a source account is rejected, not guessed", %{conn: conn} do
      capture_log(fn ->
        conn = post(conn, webhook_path("fake"), %{"id" => "evt-x", "type" => "no_account"})

        assert json_response(conn, 200) ==
                 %{"status" => "rejected", "reason" => "missing_account_id"}
      end)

      assert event_count() == 0
    end

    test "AC-7: a crash in extract_account_id/1 is contained and reported", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = post(conn, webhook_path("fake"), %{"id" => "evt-x", "type" => "raise_account"})

          assert json_response(conn, 200) ==
                   %{"status" => "rejected", "reason" => "missing_account_id"}
        end)

      assert log =~ "integration callback raised source_key=fake callback=extract_account_id"
      assert event_count() == 0

      # and the next request is served normally
      assert json_response(post(build_conn(), webhook_path("fake"), @payload), 200) == accepted()
    end

    test "a source's event id seen through another tenant's account is a duplicate",
         %{conn: conn, tenant: a} do
      b = tenant!(0, "Tenant B")
      integration!(b, "fake", "account-b")

      assert json_response(post(conn, webhook_path("fake"), %{"id" => "same"}), 200) == accepted()

      assert json_response(
               post(build_conn(), webhook_path("fake"), %{
                 "id" => "same",
                 "account" => "account-b"
               }),
               200
             ) == %{"status" => "duplicate"}

      assert [%{tenant_id: owner}] = Repo.all(WebhookEvent)
      assert owner == a.id
      assert Mensageria.list_webhook_events(b.id) == []
    end
  end
end
