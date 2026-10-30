defmodule Notifiq.Integrations.BlingContractTest do
  # Spec 003, AC-6: the Bling adapter passes the shared contract suite from Spec 002.
  @sample Notifiq.Test.BlingHelpers.sample_payload()

  use Notifiq.Integrations.AdapterContractCase,
    adapter: Notifiq.Integrations.Bling,
    valid_payload: @sample,
    ignored_payload: put_in(@sample, ["data", "situacao", "id"], 999),
    conn_builder: {Notifiq.Test.BlingHelpers, :signed_conn},
    credentials: %{client_secret: "test-bling-secret"}
end
