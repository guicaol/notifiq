defmodule Notifiq.Test.OtherFakeSource do
  @moduledoc "Second fake adapter, used to prove one source's failure doesn't affect another."

  @behaviour Notifiq.Integrations.Source

  alias Notifiq.Mensageria.CanonicalEvent

  @impl true
  def source_key, do: :other_fake

  @impl true
  def metadata do
    %{
      name: "Outra Fonte Fake",
      account_label: "Conta da outra fonte",
      # `numero_pedido` repeats the other fake's on purpose: the first one must win.
      variables: [
        %{name: "codigo_rastreio", label: "Código de rastreio", example: "BR123456789"},
        %{name: "numero_pedido", label: "Pedido (outra fonte)", example: "9999"}
      ]
    }
  end

  @impl true
  def verify_authenticity(_conn, _credentials), do: :ok

  @impl true
  def extract_event_id(payload), do: to_string(payload["id"])

  def default_account, do: "other-account"

  @impl true
  def extract_account_id(%{"account" => account}) when is_binary(account), do: {:ok, account}
  def extract_account_id(%{"id" => _id}), do: {:ok, default_account()}
  def extract_account_id(_payload), do: :error

  @impl true
  def parse(payload) do
    {:ok,
     %CanonicalEvent{
       source: Atom.to_string(source_key()),
       external_event_id: extract_event_id(payload),
       event_type: "order_created",
       recipient: %{name: nil, phone: "+5511988887777"},
       context: %{"codigo_rastreio" => payload["tracking"], "numero_pedido" => payload["order"]},
       raw: payload
     }}
  end
end
