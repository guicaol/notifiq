defmodule Notifiq.Channels.TwilioTest do
  # Not async: log capture is global and the dispatcher runs the provider in a task.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notifiq.Channels.Dispatcher
  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Channels.Twilio
  alias Notifiq.Test.TwilioStub

  @stub Notifiq.Channels.Twilio
  @account_sid "AC00000000000000000000000000000000"
  @auth_token "test-twilio-token"
  @phone "+5511999998888"
  @body "Pedido 1234 faturado"

  defp credentials(overrides \\ %{}) do
    Map.merge(
      %{account_sid: @account_sid, auth_token: @auth_token, sms_from: "+15005550006"},
      overrides
    )
  end

  defp message(overrides \\ []) do
    struct!(
      %OutboundMessage{channel: :sms, to: @phone, body: @body, idempotency_key: "key-1"},
      overrides
    )
  end

  # Stubs Twilio with `fun` and reports every request to the test process.
  defp stub_twilio(fun) do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:twilio_request, conn, URI.decode_query(raw)})
      fun.(conn)
    end)
  end

  defp respond(conn, status, body) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp created(conn, overrides \\ %{}), do: respond(conn, 201, TwilioStub.created(%{}, overrides))

  describe "request (AC-2)" do
    test "posts a form to the account's Messages endpoint with Basic auth" do
      stub_twilio(&created/1)

      assert {:ok, %SendReceipt{}} = Twilio.send_message(message(), credentials())

      assert_received {:twilio_request, conn, params}
      assert conn.method == "POST"
      assert conn.request_path == "/2010-04-01/Accounts/#{@account_sid}/Messages.json"

      assert Plug.Conn.get_req_header(conn, "authorization") ==
               ["Basic " <> Base.encode64("#{@account_sid}:#{@auth_token}")]

      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "application/x-www-form-urlencoded"
      assert params == %{"To" => @phone, "Body" => @body, "From" => "+15005550006"}
    end

    test "the Messaging Service prevails over a From number" do
      stub_twilio(&created/1)

      creds = credentials(%{messaging_service_sid: "MG00000000000000000000000000000000"})
      assert {:ok, _receipt} = Twilio.send_message(message(), creds)

      assert_received {:twilio_request, _conn, params}
      assert params["MessagingServiceSid"] == "MG00000000000000000000000000000000"
      refute Map.has_key?(params, "From")
    end

    test "AC-7: an API key authenticates while the URL keeps the account" do
      stub_twilio(&created/1)

      creds = credentials(%{api_key_sid: "SK123", api_key_secret: "api-secret"})
      assert {:ok, _receipt} = Twilio.send_message(message(), creds)

      assert_received {:twilio_request, conn, _params}
      assert conn.request_path =~ "/Accounts/#{@account_sid}/"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("SK123:api-secret")
             ]
    end

    test "AC-11: sends no idempotency header (the docs don't promise one for Messages)" do
      stub_twilio(&created/1)
      Twilio.send_message(message(), credentials())

      assert_received {:twilio_request, conn, _params}
      refute Enum.any?(conn.req_headers, fn {name, _value} -> name =~ ~r/idempoten/i end)
    end
  end

  describe "receipt (AC-3)" do
    test "maps a 201 to a receipt without personal data in raw" do
      stub_twilio(&created/1)

      assert {:ok, %SendReceipt{} = receipt} = Twilio.send_message(message(), credentials())

      assert receipt.provider == "twilio"
      assert receipt.provider_message_id == "SM0123456789abcdef0123456789abcdef"
      assert receipt.status == :queued
      assert receipt.raw["sid"] == receipt.provider_message_id
      assert receipt.raw["num_segments"] == "1"
      refute Map.has_key?(receipt.raw, "to")
      refute Map.has_key?(receipt.raw, "from")
      refute Map.has_key?(receipt.raw, "body")
    end

    test "maps Twilio statuses to receipt statuses" do
      for {twilio_status, expected} <- [
            queued: :queued,
            accepted: :queued,
            scheduled: :queued,
            sending: :sent,
            sent: :sent
          ] do
        stub_twilio(&created(&1, %{"status" => Atom.to_string(twilio_status)}))

        assert {:ok, %SendReceipt{status: ^expected}} =
                 Twilio.send_message(message(), credentials())
      end
    end

    test "a failed/undelivered/canceled status at creation is permanent" do
      for status <- ["failed", "undelivered", "canceled"] do
        stub_twilio(&created(&1, %{"status" => status}))

        assert {:error, {:permanent, :rejected}} = Twilio.send_message(message(), credentials())
      end
    end

    test "an unknown status, a missing sid or a non-JSON body is :uncertain" do
      stub_twilio(&created(&1, %{"status" => "mystery"}))

      assert {:error, {:uncertain, :invalid_response}} =
               Twilio.send_message(message(), credentials())

      stub_twilio(&created(&1, %{"sid" => nil}))

      assert {:error, {:uncertain, :invalid_response}} =
               Twilio.send_message(message(), credentials())

      stub_twilio(&Plug.Conn.send_resp(&1, 200, "not json"))

      assert {:error, {:uncertain, :invalid_response}} =
               Twilio.send_message(message(), credentials())
    end
  end

  describe "error classification (AC-4)" do
    @cases [
      {429, %{"status" => 429, "code" => 20_429, "message" => "x"}, {:retryable, :rate_limited}},
      {400, %{"status" => 400, "code" => 20_429, "message" => "x"}, {:retryable, :rate_limited}},
      {401, %{"status" => 401, "message" => "x"}, {:permanent, :invalid_credentials}},
      {403, %{"status" => 403, "message" => "x"}, {:permanent, :forbidden}},
      {400, %{"status" => 400, "code" => 21_211, "message" => "x"},
       {:permanent, :invalid_number}},
      {400, %{"status" => 400, "code" => 21_614, "message" => "x"},
       {:permanent, :not_a_mobile_number}},
      {400, %{"status" => 400, "code" => 21_610, "message" => "x"},
       {:permanent, :recipient_unsubscribed}},
      {400, %{"status" => 400, "code" => 21_408, "message" => "x"},
       {:permanent, :region_not_permitted}},
      {400, %{"status" => 400, "code" => 21_608, "message" => "x"},
       {:permanent, :account_unverified}},
      {400, %{"status" => 400, "code" => 99_999, "message" => "x"}, {:permanent, :rejected}},
      {400, %{"status" => 400, "message" => "no code"}, {:permanent, :rejected}},
      {404, %{"status" => 404, "message" => "x"}, {:permanent, :rejected}},
      {500, %{"status" => 500, "message" => "x"}, {:uncertain, :provider_unavailable}},
      {503, %{"status" => 503, "message" => "x"}, {:uncertain, :provider_unavailable}}
    ]

    test "each documented HTTP status / Twilio code maps to its class and reason" do
      capture_log(fn ->
        for {status, body, expected} <- @cases do
          stub_twilio(&respond(&1, status, body))

          assert {:error, ^expected} = Twilio.send_message(message(), credentials()),
                 "HTTP #{status} #{inspect(body)}"
        end
      end)
    end

    test "an error that isn't JSON is classified by its status alone" do
      capture_log(fn ->
        stub_twilio(&Plug.Conn.send_resp(&1, 502, "<html>Bad Gateway</html>"))

        assert {:error, {:uncertain, :provider_unavailable}} =
                 Twilio.send_message(message(), credentials())

        stub_twilio(&Plug.Conn.send_resp(&1, 400, "<html>nope</html>"))
        assert {:error, {:permanent, :rejected}} = Twilio.send_message(message(), credentials())
      end)
    end
  end

  describe "transport failures (AC-5)" do
    test "a refused or unresolvable connection is safe to retry" do
      capture_log(fn ->
        for reason <- [:econnrefused, :nxdomain] do
          stub_twilio(&Req.Test.transport_error(&1, reason))

          assert {:error, {:retryable, :connection_failed}} =
                   Twilio.send_message(message(), credentials())
        end
      end)
    end

    test "a timeout or a dropped connection may have sent the message" do
      capture_log(fn ->
        stub_twilio(&Req.Test.transport_error(&1, :timeout))
        assert {:error, {:uncertain, :timeout}} = Twilio.send_message(message(), credentials())

        for reason <- [:closed, :econnreset] do
          stub_twilio(&Req.Test.transport_error(&1, reason))

          assert {:error, {:uncertain, :connection_lost}} =
                   Twilio.send_message(message(), credentials())
        end
      end)
    end
  end

  describe "missing credentials (AC-6)" do
    test "fails as permanent without making any request" do
      stub_twilio(&created/1)

      incomplete = [
        %{},
        credentials(%{account_sid: nil}),
        credentials(%{account_sid: ""}),
        credentials(%{auth_token: "  "}),
        credentials(%{auth_token: nil}),
        credentials(%{sms_from: nil}),
        %{account_sid: @account_sid, auth_token: @auth_token}
      ]

      for creds <- incomplete do
        assert {:error, {:permanent, :missing_credentials}} =
                 Twilio.send_message(message(), creds),
               inspect(creds)
      end

      refute_received {:twilio_request, _conn, _params}
    end
  end

  describe "no automatic retries (AC-8)" do
    test "a 500 and a 429 each cost exactly one request" do
      capture_log(fn ->
        for status <- [500, 429] do
          stub_twilio(&respond(&1, status, %{"status" => status, "message" => "x"}))
          Twilio.send_message(message(), credentials())

          assert_received {:twilio_request, _conn, _params}
          refute_received {:twilio_request, _conn, _params}
        end
      end)
    end
  end

  describe "logging (AC-10)" do
    test "error logs carry neither personal data nor secrets" do
      stub_twilio(
        &respond(&1, 400, %{
          "status" => 400,
          "code" => 21_211,
          "message" => "The 'To' number #{@phone} is not valid. Body: #{@body}"
        })
      )

      log =
        capture_log(fn ->
          assert {:error, {:permanent, :invalid_number}} =
                   Twilio.send_message(message(), credentials())
        end)

      assert log =~ "twilio request failed status=400 code=21211"
      refute log =~ @phone
      refute log =~ @body
      refute log =~ @auth_token
      refute log =~ @account_sid
    end

    test "transport errors log only the reason atom" do
      stub_twilio(&Req.Test.transport_error(&1, :econnrefused))

      log = capture_log(fn -> Twilio.send_message(message(), credentials()) end)

      assert log =~ "twilio request failed transport_error=econnrefused"
      refute log =~ @phone
      refute log =~ @auth_token
    end
  end

  describe "through the dispatcher (AC-9)" do
    test "the \"twilio\" key resolves to this provider, from configured credentials" do
      stub_twilio(&created/1)

      assert {:ok, %SendReceipt{provider: "twilio"}} = Dispatcher.dispatch("twilio", message())

      assert_received {:twilio_request, conn, params}

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("#{@account_sid}:#{@auth_token}")
             ]

      assert params["From"] == "+15005550006"
    end

    test "classified errors reach the caller unchanged" do
      capture_log(fn ->
        stub_twilio(&respond(&1, 429, %{"status" => 429, "code" => 20_429, "message" => "x"}))

        assert {:error, {:retryable, :rate_limited}} = Dispatcher.dispatch("twilio", message())
      end)
    end

    test "WhatsApp is refused before any request is made" do
      stub_twilio(&created/1)

      assert {:error, {:permanent, :unsupported_channel}} =
               Dispatcher.dispatch("twilio", message(channel: :whatsapp))

      refute_received {:twilio_request, _conn, _params}
    end
  end

  test "declares provider_key :twilio and SMS only (FR-2)" do
    assert Twilio.provider_key() == :twilio
    assert Twilio.supported_channels() == [:sms]
  end
end
