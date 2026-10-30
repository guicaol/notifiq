defmodule Notifiq.Channels.Dispatcher do
  @moduledoc """
  Sends a message through a registered provider and normalises every outcome
  (Spec 004).

  Checks that need no provider run first (known provider, valid message, supported
  channel) and are `:permanent`. The provider call itself runs in a task with a timeout
  and a catch-all: a crash, timeout or out-of-contract return becomes `:uncertain`
  because the message may already have left. Logs carry only `provider_key`, channel,
  class and reason — never the recipient, body, credentials or exception text, since
  those may hold personal data or secrets (FR-10).
  """

  require Logger

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.Registry
  alias Notifiq.Channels.SendReceipt

  @classes [:retryable, :permanent, :uncertain]

  @type result ::
          {:ok, SendReceipt.t()}
          | {:error, {Notifiq.Channels.Provider.error_class(), atom()}}

  @spec dispatch(String.t(), OutboundMessage.t()) :: result()
  def dispatch(provider_key, message) when is_binary(provider_key) do
    started = System.monotonic_time()
    result = do_dispatch(provider_key, message)

    :telemetry.execute(
      [:notifiq, :channels, :dispatch],
      %{duration: System.monotonic_time() - started},
      %{provider: provider_key, channel: channel_of(message), outcome: outcome(result)}
    )

    result
  end

  defp do_dispatch(provider_key, message) do
    with {:ok, provider} <- fetch_provider(provider_key),
         :ok <- validate(message),
         :ok <- check_channel(provider, message) do
      call_provider(provider, provider_key, message)
    end
  end

  defp fetch_provider(provider_key) do
    case Registry.fetch(provider_key) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:permanent, :unknown_provider}}
    end
  end

  defp validate(message) do
    case OutboundMessage.validate(message) do
      :ok -> :ok
      {:error, :invalid_message} -> {:error, {:permanent, :invalid_message}}
    end
  end

  defp check_channel(provider, %OutboundMessage{channel: channel}) do
    if channel in provider.supported_channels() do
      :ok
    else
      {:error, {:permanent, :unsupported_channel}}
    end
  end

  defp call_provider(provider, provider_key, message) do
    credentials = credentials_for(provider_key)

    task =
      Task.async(fn ->
        try do
          {:returned, provider.send_message(message, credentials)}
        catch
          kind, reason -> {:raised, describe(kind, reason)}
        end
      end)

    case Task.yield(task, callback_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:returned, value}} ->
        normalize(value, provider_key, message)

      {:ok, {:raised, description}} ->
        log_failure("provider raised", provider_key, message, "error=#{description}")
        {:error, {:uncertain, :provider_crashed}}

      nil ->
        log_failure("provider timed out", provider_key, message, "")
        {:error, {:uncertain, :timeout}}

      {:exit, _reason} ->
        log_failure("provider exited", provider_key, message, "")
        {:error, {:uncertain, :provider_crashed}}
    end
  end

  defp normalize({:ok, %SendReceipt{} = receipt}, _provider_key, _message), do: {:ok, receipt}

  defp normalize({:error, {class, reason}} = error, _provider_key, _message)
       when class in @classes and is_atom(reason) do
    error
  end

  defp normalize(_other, provider_key, message) do
    log_failure("provider returned an invalid value", provider_key, message, "")
    {:error, {:uncertain, :invalid_provider_response}}
  end

  # Never include exception messages or stacktraces: they can embed the recipient
  # or body (e.g. a FunctionClauseError prints its arguments).
  defp describe(:error, %{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp describe(kind, _reason), do: Atom.to_string(kind)

  defp log_failure(text, provider_key, message, extra) do
    Logger.error(
      String.trim("#{text} provider_key=#{provider_key} channel=#{channel_of(message)} #{extra}"),
      provider_key: provider_key
    )
  end

  defp channel_of(%OutboundMessage{channel: channel}), do: channel
  defp channel_of(_other), do: nil

  defp outcome({:ok, _receipt}), do: :ok
  defp outcome({:error, {class, _reason}}), do: class

  # Credentials per provider come from runtime config until per-tenant credentials
  # exist (multi-tenancy spec); they are never hardcoded in source.
  defp credentials_for(provider_key) do
    :notifiq |> Application.get_env(:channel_credentials, %{}) |> Map.get(provider_key, %{})
  end

  defp callback_timeout, do: Application.get_env(:notifiq, :channel_callback_timeout, 10_000)
end
