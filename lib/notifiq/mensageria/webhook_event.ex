defmodule Notifiq.Mensageria.WebhookEvent do
  @moduledoc """
  A canonical event received from a source. `(source, external_event_id)` is unique
  at the database level, which is what makes ingestion idempotent (Constitution
  principle 4).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "webhook_events" do
    field :source, :string
    field :external_event_id, :string
    field :event_type, :string
    field :status, :string, default: "received"
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end
end
