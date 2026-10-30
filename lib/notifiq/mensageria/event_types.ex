defmodule Notifiq.Mensageria.EventTypes do
  @moduledoc """
  The closed list of canonical event types a message template can be written for
  (Spec 009). The canonical event schema says it "grows by PR, it is not free": adding a
  type means adding it here, so a template can never target a name nobody emits.
  """

  @types ~w(
    order_created
    order_invoiced
    order_shipped
    auth_code_requested
    marketing_campaign_triggered
  )

  @doc "Every known event type."
  @spec all() :: [String.t()]
  def all, do: @types

  @doc "True when `type` is a known event type."
  @spec valid?(term()) :: boolean()
  def valid?(type), do: type in @types
end
