defmodule Notifiq.Test.FakeSource do
  @moduledoc """
  Fake adapter for tests. Its behaviour is driven by the request so a single module
  covers every scenario of Spec 002:

    * header `x-fake-signature: invalid` -> `verify_authenticity/2` fails
    * header `x-fake-sleep: <ms>`        -> `verify_authenticity/2` sleeps first
    * payload `"type"`: `"ignore"` | `"raise"` | `"invalid"` | anything else (valid)
  """

  @behaviour Notifiq.Integrations.Source

  alias Notifiq.Mensageria.CanonicalEvent

  @impl true
  def source_key, do: :fake

  @impl true
  def verify_authenticity(conn, _credentials) do
    case Plug.Conn.get_req_header(conn, "x-fake-sleep") do
      [ms] -> ms |> String.to_integer() |> Process.sleep()
      [] -> :ok
    end

    case Plug.Conn.get_req_header(conn, "x-fake-signature") do
      ["invalid"] -> {:error, :invalid_signature}
      _ -> :ok
    end
  end

  @impl true
  def extract_event_id(payload), do: to_string(payload["id"])

  @impl true
  def parse(%{"type" => "ignore"}), do: {:ok, :ignore}
  def parse(%{"type" => "raise"}), do: raise("boom from fake adapter")
  def parse(%{"type" => "invalid"}), do: {:error, :invalid_phone}

  def parse(payload) do
    {:ok,
     %CanonicalEvent{
       source: Atom.to_string(source_key()),
       external_event_id: extract_event_id(payload),
       event_type: "order_created",
       recipient: %{name: payload["name"], phone: "+5511999998888"},
       context: %{"numero_pedido" => payload["order"]},
       raw: payload
     }}
  end
end
