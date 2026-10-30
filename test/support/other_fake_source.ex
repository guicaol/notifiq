defmodule Notifiq.Test.OtherFakeSource do
  @moduledoc "Second fake adapter, used to prove one source's failure doesn't affect another."

  @behaviour Notifiq.Integrations.Source

  alias Notifiq.Mensageria.CanonicalEvent

  @impl true
  def source_key, do: :other_fake

  @impl true
  def verify_authenticity(_conn, _credentials), do: :ok

  @impl true
  def extract_event_id(payload), do: to_string(payload["id"])

  @impl true
  def parse(payload) do
    {:ok,
     %CanonicalEvent{
       source: Atom.to_string(source_key()),
       external_event_id: extract_event_id(payload),
       event_type: "order_created",
       recipient: %{name: nil, phone: "+5511988887777"},
       context: %{},
       raw: payload
     }}
  end
end
