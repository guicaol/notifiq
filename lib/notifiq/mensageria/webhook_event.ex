defmodule Notifiq.Mensageria.WebhookEvent do
  @moduledoc """
  A canonical event received from a source. `(source, external_event_id)` is unique
  at the database level, which is what makes ingestion idempotent (Constitution
  principle 4).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  # What became of the event (Spec 009). It starts `received`; the `EventWorker` settles it.
  @statuses ~w(received dispatched skipped_no_template render_failed insufficient_credits invalid_request)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t(),
          source: String.t(),
          external_event_id: String.t(),
          event_type: String.t(),
          status: String.t(),
          payload: map()
        }

  @doc "Every status an event can have."
  def statuses, do: @statuses

  schema "webhook_events" do
    field :tenant_id, :binary_id
    field :source, :string
    field :external_event_id, :string
    field :event_type, :string
    field :status, :string, default: "received"
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end
end
