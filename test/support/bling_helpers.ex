defmodule Notifiq.Test.BlingHelpers do
  @moduledoc "Fixtures and request signing helpers for the Bling adapter tests (Spec 003)."

  import Phoenix.ConnTest, only: [build_conn: 0]

  @secret "test-bling-secret"
  @sample_path Path.expand(
                 "../../specs/003-adapter-bling/contracts/bling_webhook_sample.json",
                 __DIR__
               )

  @doc "The client secret configured for Bling in the test environment."
  def secret, do: @secret

  @doc "Credentials as `Notifiq.Integrations.Ingestion` hands them to the adapter."
  def credentials, do: %{client_secret: @secret}

  @doc "The sample webhook from the spec's contracts, decoded."
  def sample_payload, do: @sample_path |> File.read!() |> Jason.decode!()

  @doc "Value of the `X-Bling-Signature-256` header for `body`."
  def sign(body, secret \\ @secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  @doc "A conn as the adapter sees it after the endpoint: signature header + cached raw body."
  def signed_conn(:valid), do: signed_conn(sample_payload(), @secret)
  def signed_conn(:invalid), do: signed_conn(sample_payload(), "wrong-secret")

  def signed_conn(payload, secret) when is_map(payload) do
    body = Jason.encode!(payload)

    build_conn()
    |> Plug.Conn.put_req_header("x-bling-signature-256", sign(body, secret))
    |> Plug.Conn.assign(:raw_body, body)
  end
end
