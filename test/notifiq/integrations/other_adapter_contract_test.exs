defmodule Notifiq.Integrations.OtherAdapterContractTest do
  use Notifiq.Integrations.AdapterContractCase,
    adapter: Notifiq.Test.OtherFakeSource,
    valid_payload: %{"id" => "evt-9"}
end
