defmodule Notifiq.Channels.SendReceipt do
  @moduledoc """
  What a provider returns when it accepted a message (Spec 004).

  `raw` keeps the provider's original response for audit only; the core never reads it.
  """

  @enforce_keys [:provider, :provider_message_id, :status]
  defstruct provider: nil, provider_message_id: nil, status: nil, raw: %{}

  @type status :: :queued | :sent

  @type t :: %__MODULE__{
          provider: String.t(),
          provider_message_id: String.t(),
          status: status(),
          raw: map()
        }

  @statuses [:queued, :sent]

  @doc "Statuses a provider may report at acceptance time."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end
