defmodule Notifiq.Mensageria.EventWorkerTest do
  # Not async: the log tests change the log level of one module.
  use Notifiq.DataCase, async: false
  use Oban.Testing, repo: Notifiq.Repo

  import ExUnit.CaptureLog
  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Templates

  @phone "+5511999998888"

  setup do
    tenant = tenant!(5)
    %{tenant: tenant}
  end

  defp run(event),
    do: perform_job(EventWorker, %{webhook_event_id: event.id, tenant_id: event.tenant_id})

  defp status(event), do: Mensageria.get_webhook_event(event.tenant_id, event.id).status
  defp logs(tenant), do: Mensageria.list_message_logs(tenant.id)

  describe "the event's tenant and existence" do
    test "cancels the job when the event no longer exists", %{tenant: tenant} do
      assert {:cancel, :webhook_event_not_found} =
               perform_job(EventWorker, %{
                 webhook_event_id: Ecto.UUID.generate(),
                 tenant_id: tenant.id
               })
    end

    test "AC-12 (Spec 008): loads the event only through the job's tenant", %{tenant: tenant} do
      other = tenant!(5)
      event = event!(tenant)
      template!(tenant)

      assert {:cancel, :webhook_event_not_found} =
               perform_job(EventWorker, %{webhook_event_id: event.id, tenant_id: other.id})

      assert logs(tenant) == []
      assert status(event) == "received"
    end
  end

  describe "with a template (AC-5)" do
    test "reserves the dispatch with the rendered text and the event's recipient", %{
      tenant: tenant
    } do
      template = template!(tenant)
      event = event!(tenant)

      assert :ok = run(event)

      assert [%MessageLog{} = log] = logs(tenant)
      assert log.body == "Olá Maria da Silva, seu pedido 1234 foi recebido."
      assert log.recipient == @phone
      assert log.provider == template.provider
      assert log.channel == "sms"
      assert log.cost == 1
      assert log.status == "pending"
      assert log.webhook_event_id == event.id

      assert balance(tenant) == 4
      assert status(event) == "dispatched"
      assert_invariant!(tenant.id)
    end

    test "enqueues the send for the log", %{tenant: tenant} do
      template!(tenant)
      event = event!(tenant)

      assert :ok = run(event)

      assert [%MessageLog{id: log_id}] = logs(tenant)
      assert [job] = all_enqueued(worker: DispatchWorker)
      assert job.args == %{"tenant_id" => tenant.id, "message_log_id" => log_id}
    end

    test "charges the cost the template declares", %{tenant: tenant} do
      template!(tenant, %{cost: 3})

      assert :ok = tenant |> event!() |> run()

      assert [%MessageLog{cost: 3}] = logs(tenant)
      assert balance(tenant) == 2
    end

    test "picks the template of the event's type", %{tenant: tenant} do
      template!(tenant, %{event_type: "order_created", body: "criado {{numero_pedido}}"})
      template!(tenant, %{event_type: "order_shipped", body: "enviado {{numero_pedido}}"})

      assert :ok = tenant |> event!("evt", nil, "order_shipped") |> run()

      assert [%MessageLog{body: "enviado 1234"}] = logs(tenant)
    end

    test "uses the default when the event has no customer name", %{tenant: tenant} do
      template!(tenant)

      payload =
        canonical_payload(%{"context" => %{"numero_pedido" => "9", "nome_cliente" => nil}})

      assert :ok = tenant |> event!("evt", payload) |> run()

      assert [%MessageLog{body: "Olá cliente, seu pedido 9 foi recebido."}] = logs(tenant)
    end

    test "the customer's name can't inject anything into the message", %{tenant: tenant} do
      template!(tenant, %{body: "Olá {{nome_cliente}}, pedido {{numero_pedido}}."})

      payload =
        canonical_payload(%{
          "context" => %{
            "numero_pedido" => "1234",
            "nome_cliente" => "{{numero_pedido}}\r\nhttp://evil.example"
          }
        })

      assert :ok = tenant |> event!("evt", payload) |> run()

      assert [%MessageLog{body: body}] = logs(tenant)
      assert body == "Olá {{numero_pedido}} http://evil.example, pedido 1234."
      refute body =~ "\n"
    end
  end

  describe "without a usable template (AC-6)" do
    test "no template at all: skipped, nothing reserved or charged", %{tenant: tenant} do
      event = event!(tenant)

      assert :ok = run(event)

      assert status(event) == "skipped_no_template"
      assert logs(tenant) == []
      assert balance(tenant) == 5
      refute_enqueued(worker: DispatchWorker)
    end

    test "a deactivated template is ignored", %{tenant: tenant} do
      template = template!(tenant)
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)
      event = event!(tenant)

      assert :ok = run(event)

      assert status(event) == "skipped_no_template"
      assert logs(tenant) == []
    end

    test "a template for another event type is ignored", %{tenant: tenant} do
      template!(tenant, %{event_type: "order_shipped"})
      event = event!(tenant)

      assert :ok = run(event)

      assert status(event) == "skipped_no_template"
    end

    test "another tenant's template is never used (AC-10)", %{tenant: tenant} do
      other = tenant!(5)
      template!(other)
      event = event!(tenant)

      assert :ok = run(event)

      assert status(event) == "skipped_no_template"
      assert logs(tenant) == []
      assert logs(other) == []
      assert balance(other) == 5
    end
  end

  describe "failures that end the job (AC-7, AC-8)" do
    test "a value the template needs is missing: render_failed, nothing charged", %{
      tenant: tenant
    } do
      template!(tenant, %{body: "Pedido {{numero_pedido}}"})
      event = event!(tenant, "evt", canonical_payload(%{"context" => %{}}))

      assert {:cancel, {:missing_variable, "numero_pedido"}} = run(event)

      assert status(event) == "render_failed"
      assert logs(tenant) == []
      assert balance(tenant) == 5
      refute_enqueued(worker: DispatchWorker)
    end

    test "a value that isn't text is refused too", %{tenant: tenant} do
      template!(tenant, %{body: "Pedido {{numero_pedido}}"})

      event =
        event!(
          tenant,
          "evt",
          canonical_payload(%{"context" => %{"numero_pedido" => %{"x" => 1}}})
        )

      assert {:cancel, {:unsupported_value, "numero_pedido"}} = run(event)
      assert status(event) == "render_failed"
    end

    test "no credits: insufficient_credits, no job, balance untouched" do
      broke = tenant!(0)
      template!(broke)
      event = event!(broke)

      assert {:cancel, :insufficient_credits} = run(event)

      assert status(event) == "insufficient_credits"
      assert logs(broke) == []
      assert balance(broke) == 0
      refute_enqueued(worker: DispatchWorker)
    end

    test "a template dearer than the balance counts as no credits", %{tenant: tenant} do
      template!(tenant, %{cost: 6})
      event = event!(tenant)

      assert {:cancel, :insufficient_credits} = run(event)
      assert balance(tenant) == 5
    end

    test "an event without a recipient phone: invalid_request", %{tenant: tenant} do
      template!(tenant)
      event = event!(tenant, "evt", canonical_payload(%{"recipient" => %{"name" => "Maria"}}))

      assert {:cancel, :missing_recipient} = run(event)

      assert status(event) == "invalid_request"
      assert logs(tenant) == []
      assert balance(tenant) == 5
    end

    test "a recipient phone that isn't E.164: invalid_request, nothing charged", %{tenant: tenant} do
      template!(tenant)

      event =
        event!(
          tenant,
          "evt",
          canonical_payload(%{"recipient" => %{"name" => "M", "phone" => "123"}})
        )

      assert {:cancel, :invalid_request} = run(event)

      assert status(event) == "invalid_request"
      assert balance(tenant) == 5
    end

    test "a body that renders blank is refused before anything is charged", %{tenant: tenant} do
      template!(tenant, %{body: "{{nome_cliente|}}"})
      event = event!(tenant, "evt", canonical_payload(%{"context" => %{}}))

      assert {:cancel, :invalid_request} = run(event)
      assert balance(tenant) == 5
    end
  end

  describe "running it again (AC-9)" do
    test "never reserves or charges twice", %{tenant: tenant} do
      template!(tenant)
      event = event!(tenant)

      assert :ok = run(event)
      assert :ok = run(event)
      assert :ok = run(event)

      assert [_one_log] = logs(tenant)
      assert [_one_job] = all_enqueued(worker: DispatchWorker)
      assert balance(tenant) == 4
      assert status(event) == "dispatched"
      assert_invariant!(tenant.id)
    end

    test "a repeat after the template changed doesn't overwrite the outcome", %{tenant: tenant} do
      template = template!(tenant)
      event = event!(tenant)
      assert :ok = run(event)

      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)
      assert :ok = run(event)

      assert status(event) == "dispatched"
      assert [_one_log] = logs(tenant)
      assert balance(tenant) == 4
    end

    test "a terminal failure isn't overwritten by a later success", %{tenant: tenant} do
      template!(tenant, %{body: "Pedido {{numero_pedido}}"})
      event = event!(tenant, "evt", canonical_payload(%{"context" => %{}}))
      assert {:cancel, _reason} = run(event)

      assert status(event) == "render_failed"
      assert :ok = Mensageria.update_event_status(tenant.id, event.id, "dispatched")
      assert status(event) == "render_failed"
    end
  end

  describe "update_event_status/3" do
    test "only moves an event out of received, and only for its tenant", %{tenant: tenant} do
      other = tenant!()
      event = event!(tenant)

      assert :ok = Mensageria.update_event_status(other.id, event.id, "dispatched")
      assert status(event) == "received"

      assert :ok = Mensageria.update_event_status(tenant.id, event.id, "dispatched")
      assert status(event) == "dispatched"
    end

    test "refuses unknown statuses and a return to received", %{tenant: tenant} do
      event = event!(tenant)

      assert {:error, :invalid_status} =
               Mensageria.update_event_status(tenant.id, event.id, "exploded")

      assert {:error, :invalid_status} =
               Mensageria.update_event_status(tenant.id, event.id, "received")

      assert status(event) == "received"
    end
  end

  describe "logs (AC-12)" do
    test "never carry the text, the customer's name or the phone number", %{tenant: tenant} do
      Logger.put_module_level(EventWorker, :info)
      on_exit(fn -> Logger.delete_module_level(EventWorker) end)

      template!(tenant)
      template!(tenant, %{event_type: "order_shipped", body: "Pedido {{numero_pedido}}"})
      ok = event!(tenant)
      failing = event!(tenant, "evt", canonical_payload(%{"context" => %{}}), "order_shipped")

      log =
        capture_log([level: :info], fn ->
          run(ok)
          run(failing)
        end)

      assert log =~ "event settled status=dispatched"
      assert log =~ "event settled status=render_failed"
      refute log =~ "Maria"
      refute log =~ "pedido 1234"
      refute log =~ "5511999998888"
    end
  end
end
