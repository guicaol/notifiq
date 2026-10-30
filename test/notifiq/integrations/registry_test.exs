defmodule Notifiq.Integrations.RegistryTest do
  # Mutates application env, so it can't run concurrently with other tests.
  use ExUnit.Case, async: false

  alias Notifiq.Integrations.Registry

  setup do
    original = Application.get_env(:notifiq, :integration_sources)
    on_exit(fn -> Application.put_env(:notifiq, :integration_sources, original) end)
    :ok
  end

  test "fetch/1 resolves a registered key and is case sensitive" do
    assert {:ok, Notifiq.Test.FakeSource} = Registry.fetch("fake")
    assert :error = Registry.fetch("Fake")
    assert :error = Registry.fetch("missing")
  end

  test "validate!/0 passes for the configured adapters" do
    assert :ok = Registry.validate!()
  end

  test "validate!/0 raises for a module that can't be loaded" do
    Application.put_env(:notifiq, :integration_sources, %{"ghost" => Notifiq.DoesNotExist})
    assert_raise ArgumentError, ~r/could not be loaded/, &Registry.validate!/0
  end

  test "validate!/0 raises for an adapter missing callbacks" do
    Application.put_env(:notifiq, :integration_sources, %{"not_an_adapter" => Notifiq.Health})
    assert_raise ArgumentError, ~r/does not implement/, &Registry.validate!/0
  end

  test "validate!/0 raises when source_key/0 doesn't match the registered key" do
    Application.put_env(:notifiq, :integration_sources, %{"wrong" => Notifiq.Test.FakeSource})
    assert_raise ArgumentError, ~r/does not match the registered key/, &Registry.validate!/0
  end

  test "validate!/0 raises for an adapter without metadata/0 (Spec 010, AC-13)" do
    Application.put_env(:notifiq, :integration_sources, %{
      "no_metadata" => Notifiq.Test.NoMetadataSource
    })

    assert_raise ArgumentError, ~r/does not implement.*metadata/, &Registry.validate!/0
  end

  test "describe_all/0 lists every source with the name and label its adapter gives" do
    assert [
             %{key: "bling", name: "Bling", account_label: bling_label},
             %{key: "fake", name: "Fonte Fake"},
             %{key: "other_fake", name: "Outra Fonte Fake"}
           ] = Registry.describe_all()

    assert bling_label =~ "companyId"
  end

  test "describe_all/0 is empty without sources" do
    Application.put_env(:notifiq, :integration_sources, %{})
    assert Registry.describe_all() == []
  end
end
