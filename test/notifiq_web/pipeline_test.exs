defmodule NotifiqWeb.PipelineTest do
  # Spec 009, AC-11: the whole path, from a signed Bling webhook to the provider.
  #
  #   webhook -> tenant (integration) -> event -> template -> credit reserved -> send -> log
  #
  # Each Oban job is run by hand, in the order the queues would run them.
  use NotifiqWeb.ConnCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Test.BlingHelpers

  @company_id "12345678901234567890123456789012"

  setup do
    tenant = tenant!(3, "Merchant")
    integration!(tenant, "bling", @company_id)

    template!(tenant, %{
      event_type: "order_invoiced",
      body: "Olá {{nome_cliente|cliente}}, seu pedido {{numero_pedido}} foi faturado."
    })

    %{tenant: tenant}
  end

  defp webhook(conn, payload \\ BlingHelpers.sample_payload()) do
    body = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-bling-signature-256", BlingHelpers.sign(body))
    |> post("/api/webhooks/bling", body)
  end

  # Runs the two jobs a webhook leads to, as the queues would, and returns what the
  # event worker answered (an outcome like :insufficient_credits is a result, not a crash).
  defp run_pipeline do
    results = for job <- all_enqueued(worker: EventWorker), do: perform_job(EventWorker, job.args)

    for job <- all_enqueued(worker: DispatchWorker) do
      assert :ok = perform_job(DispatchWorker, job.args)
    end

    results
  end

  test "a signed Bling webhook ends as a sent SMS, charged once", %{conn: conn, tenant: tenant} do
    assert json_response(webhook(conn), 200) == %{"status" => "accepted"}

    # nothing is sent while the request is being answered
    assert Mensageria.list_message_logs(tenant.id) == []
    assert balance(tenant) == 3

    run_pipeline()

    assert [%MessageLog{} = log] = Mensageria.list_message_logs(tenant.id)
    assert log.status == "sent"
    assert log.body == "Olá Maria da Silva, seu pedido 1234 foi faturado."
    assert log.recipient == "+5511999998888"
    assert log.provider == "fake_sms"
    assert log.attempts == 1
    # the provider received the log id as its idempotency key
    assert log.provider_message_id == "fake-" <> log.id

    assert balance(tenant) == 2
    assert_invariant!(tenant.id)

    assert [%{status: "dispatched", tenant_id: owner}] = Mensageria.list_webhook_events(tenant.id)
    assert owner == tenant.id
  end

  test "Bling's retry of the same event doesn't send or charge again", %{
    conn: conn,
    tenant: tenant
  } do
    assert json_response(webhook(conn), 200) == %{"status" => "accepted"}
    assert json_response(webhook(build_conn()), 200) == %{"status" => "duplicate"}

    run_pipeline()
    # even if every job were run again
    run_pipeline()

    assert [%MessageLog{status: "sent"}] = Mensageria.list_message_logs(tenant.id)
    assert balance(tenant) == 2
    assert_invariant!(tenant.id)
  end

  test "an event the tenant has no template for is received but never sent", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, template} = {:ok, hd(Notifiq.Templates.list_templates(tenant.id))}
    {:ok, _} = Notifiq.Templates.deactivate_template(tenant.id, template.id)

    assert json_response(webhook(conn), 200) == %{"status" => "accepted"}
    run_pipeline()

    assert Mensageria.list_message_logs(tenant.id) == []
    assert balance(tenant) == 3
    assert [%{status: "skipped_no_template"}] = Mensageria.list_webhook_events(tenant.id)
  end

  test "a permanent provider failure ends the pipeline with the credit refunded", %{
    conn: conn,
    tenant: tenant
  } do
    [template] = Notifiq.Templates.list_templates(tenant.id)

    {:ok, _} =
      Notifiq.Templates.update_template(tenant.id, template.id, %{
        body: "[scenario:permanent] Pedido {{numero_pedido}}"
      })

    assert json_response(webhook(conn), 200) == %{"status" => "accepted"}
    run_pipeline()

    assert [%MessageLog{status: "failed", last_error_reason: "invalid_number"}] =
             Mensageria.list_message_logs(tenant.id)

    assert balance(tenant) == 3
    assert_invariant!(tenant.id)
  end

  test "a tenant out of credits still receives the event, but nothing is sent", %{conn: conn} do
    broke = tenant!(0, "Broke")
    integration!(broke, "bling", "BROKE-COMPANY")
    template!(broke, %{event_type: "order_invoiced"})
    payload = Map.put(BlingHelpers.sample_payload(), "companyId", "BROKE-COMPANY")

    assert json_response(webhook(conn, payload), 200) == %{"status" => "accepted"}
    assert [{:cancel, :insufficient_credits}] = run_pipeline()

    assert Mensageria.list_message_logs(broke.id) == []
    assert balance(broke) == 0
    assert [%{status: "insufficient_credits"}] = Mensageria.list_webhook_events(broke.id)
  end

  test "two merchants are served and charged independently", %{conn: conn, tenant: tenant} do
    other = tenant!(5, "Other merchant")
    integration!(other, "bling", "OTHER-COMPANY")

    template!(other, %{event_type: "order_invoiced", body: "Outra loja: pedido {{numero_pedido}}"})

    other_payload =
      BlingHelpers.sample_payload()
      |> Map.put("companyId", "OTHER-COMPANY")
      |> Map.put("eventId", "11111111-2222-7333-8444-555555555555")

    assert json_response(webhook(conn), 200) == %{"status" => "accepted"}
    assert json_response(webhook(build_conn(), other_payload), 200) == %{"status" => "accepted"}

    run_pipeline()

    assert [%MessageLog{body: "Olá Maria da Silva, seu pedido 1234 foi faturado."}] =
             Mensageria.list_message_logs(tenant.id)

    assert [%MessageLog{body: "Outra loja: pedido 1234"}] = Mensageria.list_message_logs(other.id)

    assert balance(tenant) == 2
    assert balance(other) == 4
    assert_invariant!(tenant.id)
    assert_invariant!(other.id)
  end

  test "a webhook from a company nobody connected never reaches the templates", %{
    conn: conn,
    tenant: tenant
  } do
    payload = Map.put(BlingHelpers.sample_payload(), "companyId", "NOBODY")

    assert json_response(webhook(conn, payload), 200) == %{"status" => "unknown_account"}
    run_pipeline()

    assert Mensageria.list_message_logs(tenant.id) == []
    assert Mensageria.list_webhook_events(tenant.id) == []
    assert balance(tenant) == 3
  end
end
