defmodule Notifiq.Mensageria.EventWorker do
  @moduledoc """
  Turns a received event into a dispatch, off the request path (Constitution principle 8;
  Spec 009).

  For the event's tenant it finds the active template of the event type, renders it with
  the event's data and asks `Notifiq.Mensageria.request_dispatch/1` to reserve the credit
  and enqueue the send. What became of the event is written to `webhook_events.status`, so
  an event never disappears without a trace:

    * `dispatched` — reserved (also when this run is a repeat of an earlier one)
    * `skipped_no_template` — the tenant has no active template for this event type
    * `render_failed` — the template needs a value the event doesn't have
    * `insufficient_credits` — nothing was reserved; not retried by itself
    * `invalid_request` — the event has no usable recipient

  Running it again for the same event never reserves or charges twice: that is the
  idempotency of `request_dispatch/1`. Logs never carry the text, the name or the phone.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  require Logger

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Templates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id, "tenant_id" => tenant_id}}) do
    case Mensageria.get_webhook_event(tenant_id, id) do
      nil -> {:cancel, :webhook_event_not_found}
      %WebhookEvent{} = event -> process(event)
    end
  end

  defp process(%WebhookEvent{tenant_id: tenant_id} = event) do
    case Templates.find_active(tenant_id, event.event_type) do
      nil -> settle(event, "skipped_no_template", :ok)
      template -> dispatch(event, template)
    end
  end

  defp dispatch(event, template) do
    with {:ok, recipient} <- recipient(event),
         {:ok, body} <- render(event, template) do
      request_dispatch(event, template, recipient, body)
    else
      {:error, :missing_recipient} ->
        settle(event, "invalid_request", {:cancel, :missing_recipient})

      {:error, {:render, reason}} ->
        settle(event, "render_failed", {:cancel, reason})
    end
  end

  defp recipient(%WebhookEvent{payload: payload}) do
    case get_in(payload, ["recipient", "phone"]) do
      phone when is_binary(phone) and phone != "" -> {:ok, phone}
      _missing -> {:error, :missing_recipient}
    end
  end

  defp render(event, template) do
    case Templates.render(template, event.payload) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:render, reason}}
    end
  end

  defp request_dispatch(event, template, recipient, body) do
    result =
      Mensageria.request_dispatch(%{
        tenant_id: event.tenant_id,
        webhook_event_id: event.id,
        provider: template.provider,
        channel: template.channel,
        recipient: recipient,
        body: body,
        cost: template.cost
      })

    case result do
      {:ok, _log} ->
        settle(event, "dispatched", :ok)

      {:duplicate, _log} ->
        settle(event, "dispatched", :ok)

      {:error, :insufficient_credits} ->
        settle(event, "insufficient_credits", {:cancel, :insufficient_credits})

      {:error, :invalid_request} ->
        settle(event, "invalid_request", {:cancel, :invalid_request})

      # Transient problems (e.g. the job couldn't be inserted): let Oban try again.
      {:error, reason} when reason in [:enqueue_failed, :conflict] ->
        {:error, reason}

      # The tenant or event vanished under us: nothing left to do.
      {:error, reason} ->
        {:cancel, reason}
    end
  end

  defp settle(%WebhookEvent{} = event, status, result) do
    :ok = Mensageria.update_event_status(event.tenant_id, event.id, status)

    Logger.info("event settled status=#{status} source=#{event.source} event_id=#{event.id}")

    result
  end
end
