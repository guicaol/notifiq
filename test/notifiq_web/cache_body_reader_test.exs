defmodule NotifiqWeb.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  @parser_opts Plug.Parsers.init(
                 parsers: [:json],
                 pass: ["*/*"],
                 body_reader: {NotifiqWeb.CacheBodyReader, :read_body, []},
                 json_decoder: Jason
               )

  defp parse(path, body) do
    :post
    |> conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(@parser_opts)
  end

  test "keeps the exact raw body for webhook paths while still parsing JSON" do
    body = ~s({"id":  "evt-1",\n "n": 1})
    conn = parse("/api/webhooks/fake", body)

    assert conn.assigns.raw_body == body
    assert conn.body_params == %{"id" => "evt-1", "n" => 1}
  end

  test "does not cache the body of other paths" do
    conn = parse("/health", ~s({"a":1}))

    refute Map.has_key?(conn.assigns, :raw_body)
    assert conn.body_params == %{"a" => 1}
  end
end
