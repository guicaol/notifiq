defmodule Notifiq.Channels.Registry do
  @moduledoc """
  Resolves a provider key to its `Notifiq.Channels.Provider` module (Spec 004, FR-2).

  The mapping comes from application config (`:channel_providers`). Keys are matched
  exactly — normalising case is the configurer's job.
  """

  alias Notifiq.Channels.OutboundMessage

  @required_callbacks [provider_key: 0, supported_channels: 0, send_message: 2]

  @doc "Returns the provider module registered for `provider_key`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(provider_key) when is_binary(provider_key), do: Map.fetch(providers(), provider_key)

  @doc "All registered providers as a `provider_key => module` map."
  @spec providers() :: %{optional(String.t()) => module()}
  def providers, do: Application.get_env(:notifiq, :channel_providers, %{})

  @doc """
  Checks every configured provider and raises when one is unusable, so a broken
  registration fails the boot instead of the first dispatch (FR-3).
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(providers(), fn {key, module} -> validate_provider!(key, module) end)
  end

  defp validate_provider!(key, module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "channel provider #{inspect(key)}: module #{inspect(module)} could not be loaded"
    end

    missing =
      Enum.reject(@required_callbacks, fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)

    unless missing == [] do
      raise ArgumentError,
            "channel provider #{inspect(key)}: #{inspect(module)} does not implement " <>
              "Notifiq.Channels.Provider callbacks #{inspect(missing)}"
    end

    unless Atom.to_string(module.provider_key()) == key do
      raise ArgumentError,
            "channel provider #{inspect(key)}: #{inspect(module)}.provider_key/0 returns " <>
              "#{inspect(module.provider_key())}, which does not match the registered key"
    end

    channels = module.supported_channels()

    unless is_list(channels) and channels != [] and channels -- OutboundMessage.channels() == [] do
      raise ArgumentError,
            "channel provider #{inspect(key)}: #{inspect(module)}.supported_channels/0 returns " <>
              "#{inspect(channels)}; expected a non-empty list of #{inspect(OutboundMessage.channels())}"
    end

    :ok
  end
end
