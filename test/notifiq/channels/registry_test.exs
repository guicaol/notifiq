defmodule Notifiq.Channels.RegistryTest do
  # Mutates application env, so it can't run concurrently with other tests.
  use ExUnit.Case, async: false

  alias Notifiq.Channels.Registry

  setup do
    original = Application.get_env(:notifiq, :channel_providers)
    on_exit(fn -> Application.put_env(:notifiq, :channel_providers, original) end)
    :ok
  end

  test "AC-1: fetch/1 resolves a registered key and is case sensitive" do
    assert {:ok, Notifiq.Test.FakeProvider} = Registry.fetch("fake_sms")
    assert {:ok, Notifiq.Test.OtherFakeProvider} = Registry.fetch("fake_multi")
    assert :error = Registry.fetch("Fake_SMS")
    assert :error = Registry.fetch("missing")
  end

  test "validate!/0 passes for the configured providers" do
    assert :ok = Registry.validate!()
  end

  test "AC-10: raises for a module that can't be loaded" do
    Application.put_env(:notifiq, :channel_providers, %{"ghost" => Notifiq.DoesNotExist})
    assert_raise ArgumentError, ~r/"ghost".*could not be loaded/, &Registry.validate!/0
  end

  test "AC-10: raises for a provider missing callbacks" do
    Application.put_env(:notifiq, :channel_providers, %{"not_a_provider" => Notifiq.Health})
    assert_raise ArgumentError, ~r/"not_a_provider".*does not implement/, &Registry.validate!/0
  end

  test "AC-10: raises when provider_key/0 doesn't match the registered key" do
    Application.put_env(:notifiq, :channel_providers, %{"wrong" => Notifiq.Test.FakeProvider})

    assert_raise ArgumentError,
                 ~r/"wrong".*does not match the registered key/,
                 &Registry.validate!/0
  end

  test "AC-10: raises when supported_channels/0 is empty or has unknown channels" do
    for {name, channels} <- [empty: [], unknown: [:sms, :telegram], not_a_list: :sms] do
      module = Module.concat(Notifiq.Test, "BadChannels#{name}")
      key = "bad_#{name}"

      Module.create(
        module,
        quote do
          def provider_key, do: unquote(String.to_atom(key))
          def supported_channels, do: unquote(channels)
          def send_message(_message, _credentials), do: {:error, {:permanent, :nope}}
        end,
        Macro.Env.location(__ENV__)
      )

      Application.put_env(:notifiq, :channel_providers, %{key => module})

      assert_raise ArgumentError, ~r/supported_channels\/0 returns/, &Registry.validate!/0
    end
  end
end
