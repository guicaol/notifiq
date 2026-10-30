defmodule NotifiqWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw request body of webhook requests in
  `conn.assigns.raw_body`.

  Source adapters need the exact bytes to verify signatures (e.g. HMAC), which
  cannot be reproduced from the parsed params. Only `/api/webhooks/*` is cached so
  other requests don't pay the memory cost.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{path_info: ["api", "webhooks" | _]} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp cache(conn, chunk) do
    update_in(conn.assigns[:raw_body], &((&1 || "") <> chunk))
  end
end
