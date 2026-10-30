defmodule Notifiq.Integrations.Bling do
  @moduledoc """
  `Notifiq.Integrations.Source` adapter for Bling (Spec 003).

  ## Verified against the official docs (developer.bling.com.br/webhooks)

    * Authenticity: header `X-Bling-Signature-256` = `"sha256=" <> hex(HMAC-SHA256(body, client_secret))`.
      The HMAC is computed over the raw request body (`conn.assigns.raw_body`, kept by
      `NotifiqWeb.CacheBodyReader`), never over re-serialised JSON.
    * Envelope: `eventId`, `date`, `version`, `event` (`"<resource>.<action>"`),
      `companyId`, `data`.

  ## NOT confirmed by the docs — assumptions, all isolated in `parse/1`

  The docs show no example of `data` for `order.*` events. We assume it is the sales
  order: `data.numero`, `data.situacao.id`, `data.contato.{nome, telefone}`. If a real
  delivery shows otherwise (e.g. the phone only exists behind `GET /contatos/{id}`),
  fix `parse/1` and the fixture in `specs/003-adapter-bling/contracts/`.

  Situation ids are per Bling account. Only `9` ("Atendido") is mapped by default;
  add others (e.g. a custom "Em rota de entrega") with
  `config :notifiq, :bling_situacao_event_types, %{<id> => "order_shipped"}`.
  """

  @behaviour Notifiq.Integrations.Source

  require Logger

  alias Notifiq.Integrations.Bling.Phone
  alias Notifiq.Mensageria.CanonicalEvent

  @signature_header "x-bling-signature-256"
  @default_situacao_event_types %{9 => "order_invoiced"}
  @handled_events ["order.created", "order.updated"]

  @impl true
  def source_key, do: :bling

  @impl true
  def metadata, do: %{name: "Bling", account_label: "ID da empresa no Bling (companyId)"}

  @impl true
  def verify_authenticity(conn, credentials) do
    with {:ok, secret} <- fetch_secret(credentials),
         {:ok, signature} <- fetch_signature(conn),
         {:ok, body} <- fetch_raw_body(conn) do
      expected =
        "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

      if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @impl true
  def extract_event_id(%{"eventId" => id}) when is_binary(id) or is_integer(id), do: to_string(id)
  def extract_event_id(_payload), do: ""

  # `companyId` is part of the documented webhook envelope: the Bling company that owns the
  # order. The core maps it to a tenant through the integration the merchant connected.
  @impl true
  def extract_account_id(%{"companyId" => id}) when is_binary(id) and id != "", do: {:ok, id}

  def extract_account_id(%{"companyId" => id}) when is_integer(id),
    do: {:ok, Integer.to_string(id)}

  def extract_account_id(_payload), do: :error

  @impl true
  def parse(%{"event" => event} = payload) when event in @handled_events do
    with {:ok, data} <- fetch_data(payload),
         {:ok, event_id} <- fetch_event_id(payload),
         {:ok, situacao_id} <- fetch_situacao_id(data) do
      case Map.fetch(situacao_event_types(), situacao_id) do
        {:ok, event_type} ->
          build_event(payload, data, event_id, event_type, situacao_id)

        :error ->
          Logger.info(
            "bling situation not mapped, ignoring situacao_id=#{situacao_id} event_id=#{event_id}"
          )

          {:ok, :ignore}
      end
    end
  end

  # Other resources (product, stock, invoice...) and order.deleted never notify.
  def parse(%{"event" => _other}), do: {:ok, :ignore}
  def parse(_payload), do: {:error, :invalid_payload}

  defp build_event(payload, data, event_id, event_type, situacao_id) do
    contato = Map.get(data, "contato")

    with {:ok, phone} <- contact_phone(contato) do
      {:ok,
       %CanonicalEvent{
         source: Atom.to_string(source_key()),
         external_event_id: event_id,
         event_type: event_type,
         recipient: %{name: contact_name(contato), phone: phone},
         context: %{
           "numero_pedido" => stringify(data["numero"]),
           "nome_cliente" => contact_name(contato),
           "pedido_id" => stringify(data["id"]),
           "situacao_id" => situacao_id
         },
         raw: payload
       }}
    end
  end

  defp fetch_secret(%{client_secret: secret}) when is_binary(secret) and secret != "",
    do: {:ok, secret}

  defp fetch_secret(_credentials) do
    Logger.error("bling client secret is not configured (BLING_CLIENT_SECRET)")
    {:error, :missing_credentials}
  end

  defp fetch_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [signature | _] -> {:ok, signature}
      [] -> {:error, :missing_signature}
    end
  end

  defp fetch_raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body),
    do: {:ok, body}

  defp fetch_raw_body(_conn), do: {:error, :missing_body}

  defp fetch_data(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp fetch_data(_payload), do: {:error, :invalid_payload}

  defp fetch_event_id(payload) do
    case extract_event_id(payload) do
      "" -> {:error, :missing_event_id}
      id -> {:ok, id}
    end
  end

  defp fetch_situacao_id(%{"situacao" => %{"id" => id}}) when is_integer(id), do: {:ok, id}

  defp fetch_situacao_id(%{"situacao" => %{"id" => id}}) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_payload}
    end
  end

  defp fetch_situacao_id(_data), do: {:error, :invalid_payload}

  defp contact_phone(%{} = contato) do
    contato
    |> Map.take(["telefone", "celular"])
    |> Map.values()
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> Phone.normalize()
  end

  defp contact_phone(_contato), do: {:error, :invalid_phone}

  defp contact_name(%{"nome" => nome}) when is_binary(nome), do: nome
  defp contact_name(_contato), do: nil

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp situacao_event_types do
    Map.merge(
      @default_situacao_event_types,
      Application.get_env(:notifiq, :bling_situacao_event_types, %{})
    )
  end
end
