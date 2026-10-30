defmodule Notifiq.Integrations.BlingTest do
  # Not async: one test changes application env and another the module log level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notifiq.Integrations.Bling
  alias Notifiq.Mensageria.CanonicalEvent
  alias Notifiq.Test.BlingHelpers

  defp sample, do: BlingHelpers.sample_payload()
  defp put_contato(payload, key, value), do: put_in(payload, ["data", "contato", key], value)

  test "source_key/0 is :bling" do
    assert Bling.source_key() == :bling
  end

  describe "verify_authenticity/2 (AC-5)" do
    test "accepts a body signed with the client secret" do
      assert :ok =
               Bling.verify_authenticity(
                 BlingHelpers.signed_conn(:valid),
                 BlingHelpers.credentials()
               )
    end

    test "rejects a body signed with another secret" do
      assert {:error, :invalid_signature} =
               Bling.verify_authenticity(
                 BlingHelpers.signed_conn(:invalid),
                 BlingHelpers.credentials()
               )
    end

    test "rejects a body that was altered after signing" do
      conn = BlingHelpers.signed_conn(:valid)
      conn = Plug.Conn.assign(conn, :raw_body, conn.assigns.raw_body <> " ")

      assert {:error, :invalid_signature} =
               Bling.verify_authenticity(conn, BlingHelpers.credentials())
    end

    test "rejects a signature without the sha256= prefix" do
      conn = BlingHelpers.signed_conn(:valid)
      "sha256=" <> hex = hd(Plug.Conn.get_req_header(conn, "x-bling-signature-256"))
      conn = Plug.Conn.put_req_header(conn, "x-bling-signature-256", hex)

      assert {:error, :invalid_signature} =
               Bling.verify_authenticity(conn, BlingHelpers.credentials())
    end

    test "accepts an upper-case hex digest" do
      conn = BlingHelpers.signed_conn(:valid)
      "sha256=" <> hex = hd(Plug.Conn.get_req_header(conn, "x-bling-signature-256"))

      conn =
        Plug.Conn.put_req_header(conn, "x-bling-signature-256", "sha256=" <> String.upcase(hex))

      assert :ok = Bling.verify_authenticity(conn, BlingHelpers.credentials())
    end

    test "reports a missing signature header" do
      conn = Plug.Conn.assign(Phoenix.ConnTest.build_conn(), :raw_body, "{}")

      assert {:error, :missing_signature} =
               Bling.verify_authenticity(conn, BlingHelpers.credentials())
    end

    test "reports a missing raw body" do
      conn =
        Plug.Conn.put_req_header(
          Phoenix.ConnTest.build_conn(),
          "x-bling-signature-256",
          "sha256=ab"
        )

      assert {:error, :missing_body} = Bling.verify_authenticity(conn, BlingHelpers.credentials())
    end

    test "fails closed when the client secret is not configured" do
      conn = BlingHelpers.signed_conn(:valid)

      capture_log(fn ->
        assert {:error, :missing_credentials} = Bling.verify_authenticity(conn, %{})

        assert {:error, :missing_credentials} =
                 Bling.verify_authenticity(conn, %{client_secret: nil})

        assert {:error, :missing_credentials} =
                 Bling.verify_authenticity(conn, %{client_secret: ""})
      end)
    end
  end

  describe "extract_account_id/1 (Spec 008, AC-8)" do
    test "is the companyId of the webhook envelope" do
      assert {:ok, "12345678901234567890123456789012"} = Bling.extract_account_id(sample())
    end

    test "accepts a numeric companyId" do
      assert {:ok, "42"} = Bling.extract_account_id(%{"companyId" => 42})
    end

    test "is :error without a usable companyId, never an exception" do
      for payload <- [
            %{},
            %{"companyId" => nil},
            %{"companyId" => ""},
            %{"companyId" => %{}},
            %{"companyId" => ["x"]},
            %{"data" => %{}}
          ] do
        assert :error = Bling.extract_account_id(payload), inspect(payload)
      end
    end
  end

  describe "extract_event_id/1" do
    test "returns the eventId of the envelope" do
      assert Bling.extract_event_id(sample()) == "01968b2c-7c1e-7e4a-9d11-3b9f4f0a1234"
    end

    test "returns an empty string when there is none" do
      assert Bling.extract_event_id(%{}) == ""
    end
  end

  describe "parse/1" do
    test "AC-1: an order set to 'Atendido' (9) becomes order_invoiced" do
      assert {:ok, %CanonicalEvent{} = event} = Bling.parse(sample())

      assert event.event_type == "order_invoiced"
      assert event.source == "bling"
      assert event.external_event_id == "01968b2c-7c1e-7e4a-9d11-3b9f4f0a1234"
      assert event.recipient == %{name: "Maria da Silva", phone: "+5511999998888"}
      assert event.raw == sample()
    end

    test "AC-7: context carries numero_pedido and nome_cliente" do
      assert {:ok, event} = Bling.parse(sample())

      assert event.context["numero_pedido"] == "1234"
      assert event.context["nome_cliente"] == "Maria da Silva"
    end

    test "order.created is handled like order.updated" do
      assert {:ok, %CanonicalEvent{event_type: "order_invoiced"}} =
               Bling.parse(Map.put(sample(), "event", "order.created"))
    end

    test "AC-2: an unmapped situation is ignored and logged at info level" do
      Logger.put_module_level(Bling, :info)
      on_exit(fn -> Logger.delete_module_level(Bling) end)

      payload = put_in(sample(), ["data", "situacao", "id"], 999)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :ignore} = Bling.parse(payload)
        end)

      assert log =~ "[info]"
      assert log =~ "situacao_id=999"
    end

    test "an ignorable event does not need a phone" do
      payload =
        sample()
        |> put_in(["data", "situacao", "id"], 999)
        |> update_in(["data", "contato"], &Map.delete(&1, "telefone"))

      capture_log(fn -> assert {:ok, :ignore} = Bling.parse(payload) end)
    end

    test "a situation id sent as a string is understood" do
      assert {:ok, %CanonicalEvent{event_type: "order_invoiced"}} =
               Bling.parse(put_in(sample(), ["data", "situacao", "id"], "9"))
    end

    test "other resources and order.deleted never notify" do
      for event <- ["product.updated", "stock.updated", "invoice.created", "order.deleted"] do
        assert {:ok, :ignore} = Bling.parse(Map.put(sample(), "event", event))
      end
    end

    test "situations can be mapped through configuration" do
      Application.put_env(:notifiq, :bling_situacao_event_types, %{15 => "order_shipped"})
      on_exit(fn -> Application.delete_env(:notifiq, :bling_situacao_event_types) end)

      assert {:ok, %CanonicalEvent{event_type: "order_shipped"}} =
               Bling.parse(put_in(sample(), ["data", "situacao", "id"], 15))

      # the default mapping is kept
      assert {:ok, %CanonicalEvent{event_type: "order_invoiced"}} = Bling.parse(sample())
    end

    test "AC-4: a phone with too few digits is :invalid_phone" do
      assert {:error, :invalid_phone} = Bling.parse(put_contato(sample(), "telefone", "123"))
    end

    test "a missing phone is :invalid_phone, not an ignore" do
      payload = update_in(sample(), ["data", "contato"], &Map.delete(&1, "telefone"))

      assert {:error, :invalid_phone} = Bling.parse(payload)

      assert {:error, :invalid_phone} =
               Bling.parse(update_in(sample(), ["data"], &Map.delete(&1, "contato")))
    end

    test "falls back to celular when telefone is blank" do
      payload =
        sample()
        |> put_contato("telefone", "")
        |> put_contato("celular", "(21) 98888-7777")

      assert {:ok, %{recipient: %{phone: "+5521988887777"}}} = Bling.parse(payload)
    end

    test "a missing customer name is not an error" do
      payload = update_in(sample(), ["data", "contato"], &Map.delete(&1, "nome"))

      assert {:ok, event} = Bling.parse(payload)
      assert event.context["nome_cliente"] == nil
      assert event.recipient.name == nil
    end

    test "a missing eventId is an error, never a synthetic id" do
      assert {:error, :missing_event_id} = Bling.parse(Map.delete(sample(), "eventId"))
    end

    test "malformed payloads are errors, not exceptions" do
      assert {:error, :invalid_payload} = Bling.parse(%{})
      assert {:error, :invalid_payload} = Bling.parse(Map.delete(sample(), "data"))
      assert {:error, :invalid_payload} = Bling.parse(%{sample() | "data" => "x"})

      assert {:error, :invalid_payload} =
               Bling.parse(update_in(sample(), ["data"], &Map.delete(&1, "situacao")))
    end
  end
end
