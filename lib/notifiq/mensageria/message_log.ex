defmodule Notifiq.Mensageria.MessageLog do
  @moduledoc """
  One dispatch of one received event (Spec 006). `UNIQUE(webhook_event_id)` is what keeps
  a redelivered event from being dispatched, and charged, twice.

  Rows are created and moved between states only through `Notifiq.Mensageria`; they are
  never built from external params.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w(pending sent failed uncertain unconfirmed)
  @final_statuses ~w(sent failed unconfirmed)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t(),
          webhook_event_id: Ecto.UUID.t(),
          provider: String.t(),
          channel: String.t(),
          recipient: String.t(),
          body: String.t(),
          cost: pos_integer(),
          status: String.t(),
          attempts: non_neg_integer(),
          provider_message_id: String.t() | nil,
          last_error_class: String.t() | nil,
          last_error_reason: String.t() | nil
        }

  schema "message_logs" do
    field :tenant_id, :binary_id
    field :webhook_event_id, :binary_id
    field :provider, :string
    field :channel, :string
    field :recipient, :string
    field :body, :string
    field :cost, :integer, default: 1
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :provider_message_id, :string
    field :last_error_class, :string
    field :last_error_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All states a log can be in."
  def statuses, do: @statuses

  @doc "States no operation can leave: `sent`, `failed`, `unconfirmed`."
  def final_statuses, do: @final_statuses

  @doc "True when the log can no longer change."
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{status: status}), do: status in @final_statuses
end
