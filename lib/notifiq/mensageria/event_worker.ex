defmodule Notifiq.Mensageria.EventWorker do
  @moduledoc """
  Processes a stored webhook event asynchronously, off the request path
  (Constitution principle 8).

  For now it only loads the event: credit consumption and dispatch arrive with the
  `Mensageria` core and the dispatch worker (future specs).
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  require Logger

  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id}}) do
    case Repo.get(WebhookEvent, id) do
      nil ->
        {:discard, :webhook_event_not_found}

      %WebhookEvent{} = event ->
        Logger.info("webhook event ready for processing source=#{event.source} id=#{event.id}")
        :ok
    end
  end
end
