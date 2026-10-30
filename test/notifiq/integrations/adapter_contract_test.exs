defmodule Notifiq.Integrations.AdapterContractTest do
  # Spec 002, AC-6: the shared contract suite, run here against the fake adapter.
  # Real adapters (e.g. Bling, Spec 003) get their own file that `use`s the same case.
  use Notifiq.Integrations.AdapterContractCase,
    adapter: Notifiq.Test.FakeSource,
    valid_payload: %{"id" => "evt-1", "name" => "Maria", "order" => "100"},
    invalid_headers: [{"x-fake-signature", "invalid"}],
    ignored_payload: %{"id" => "evt-2", "type" => "ignore"}
end
