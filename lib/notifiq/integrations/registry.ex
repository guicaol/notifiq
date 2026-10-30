defmodule Notifiq.Integrations.Registry do
  @moduledoc """
  Resolves the `source_key` of a webhook URL to its adapter module (Spec 002, FR-11).

  The mapping comes from application config (`:integration_sources`), never from a
  hardcoded `case` in the controller. Keys are matched exactly — `"Bling"` and
  `"bling"` are different sources; normalising case is the configurer's job.
  """

  @required_callbacks [source_key: 0, verify_authenticity: 2, extract_event_id: 1, parse: 1]

  @doc "Returns the adapter module registered for `source_key`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(source_key) when is_binary(source_key), do: Map.fetch(sources(), source_key)

  @doc "All registered sources as a `source_key => module` map."
  @spec sources() :: %{optional(String.t()) => module()}
  def sources, do: Application.get_env(:notifiq, :integration_sources, %{})

  @doc """
  Checks every configured adapter and raises when one is unusable, so a broken
  registration fails the boot instead of the first webhook.
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(sources(), fn {key, module} -> validate_adapter!(key, module) end)
  end

  defp validate_adapter!(key, module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "integration source #{inspect(key)}: module #{inspect(module)} could not be loaded"
    end

    missing =
      Enum.reject(@required_callbacks, fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)

    unless missing == [] do
      raise ArgumentError,
            "integration source #{inspect(key)}: #{inspect(module)} does not implement " <>
              "Notifiq.Integrations.Source callbacks #{inspect(missing)}"
    end

    unless Atom.to_string(module.source_key()) == key do
      raise ArgumentError,
            "integration source #{inspect(key)}: #{inspect(module)}.source_key/0 returns " <>
              "#{inspect(module.source_key())}, which does not match the registered key"
    end

    :ok
  end
end
