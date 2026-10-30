defmodule Notifiq.Test.TwilioStub do
  @moduledoc """
  `Req.Test` stand-in for the Twilio Messages API (Spec 005, AC-12): no test reaches the
  network. `install/0` is the default behaviour used by the contract suite — a successful
  `201` for any recipient, except `+5511000000001`, which gets a `429`.
  """

  @stub Notifiq.Channels.Twilio
  @rate_limited_number "+5511000000001"

  def name, do: @stub
  def rate_limited_number, do: @rate_limited_number

  def install do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      if params["To"] == @rate_limited_number do
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"status" => 429, "code" => 20_429, "message" => "Too Many Requests"})
      else
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(created(params))
      end
    end)
  end

  @doc "A Twilio-like `201` body. It echoes `to` and `body`, like the real API does."
  def created(params, overrides \\ %{}) do
    Map.merge(
      %{
        "sid" => "SM0123456789abcdef0123456789abcdef",
        "status" => "queued",
        "to" => params["To"],
        "from" => params["From"],
        "body" => params["Body"],
        "num_segments" => "1",
        "date_created" => "Fri, 30 Oct 2026 12:00:00 +0000",
        "error_code" => nil,
        "error_message" => nil
      },
      overrides
    )
  end
end
