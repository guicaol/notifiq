defmodule Notifiq.Integrations.Ingestion do
  @moduledoc """
  Webhook ingestion pipeline (Spec 002): resolve adapter, verify authenticity,
  parse to a canonical event, store it idempotently and enqueue the async job.

  Adapter callbacks run in a supervised-by-caller task with a timeout and a
  catch-all, so a misbehaving adapter can't hang or crash the request process
  (FR-12). Idempotency rests on the `UNIQUE(source, external_event_id)` index; the
  event row and the Oban job are inserted in one transaction, so a stored event
  always has its job and a duplicate never gets a second one.
  """

  require Logger

  alias Ecto.Multi
  alias Notifiq.Integrations.Registry
  alias Notifiq.Mensageria.CanonicalEvent
  alias Notifiq.Mensageria.EventWorker
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo

  @type success :: :accepted | :duplicate | :ignored
  @type failure ::
          :not_found | :unauthorized | :internal | {:unprocessable, atom()}

  @spec ingest(String.t(), Plug.Conn.t(), map()) :: {:ok, success()} | {:error, failure()}
  def ingest(source_key, %Plug.Conn{} = conn, payload) when is_map(payload) do
    with {:ok, adapter} <- fetch_adapter(source_key),
         :ok <- verify(adapter, source_key, conn),
         {:ok, parsed} <- parse(adapter, source_key, payload) do
      store(source_key, parsed)
    end
  end

  defp fetch_adapter(source_key) do
    case Registry.fetch(source_key) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :not_found}
    end
  end

  defp verify(adapter, source_key, conn) do
    credentials = credentials_for(source_key)

    case call(source_key, :verify_authenticity, fn ->
           adapter.verify_authenticity(conn, credentials)
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.info("webhook rejected source_key=#{source_key} reason=#{inspect(reason)}")
        {:error, :unauthorized}

      {:ok, other} ->
        unexpected(source_key, :verify_authenticity, other)

      :failed ->
        {:error, :internal}
    end
  end

  defp parse(adapter, source_key, payload) do
    case call(source_key, :parse, fn -> adapter.parse(payload) end) do
      {:ok, {:ok, :ignore}} ->
        {:ok, :ignore}

      {:ok, {:ok, %CanonicalEvent{} = event}} ->
        {:ok, event}

      {:ok, {:error, reason}} when is_atom(reason) ->
        Logger.warning("webhook event rejected source_key=#{source_key} reason=#{reason}")
        {:error, {:unprocessable, reason}}

      {:ok, other} ->
        unexpected(source_key, :parse, other)

      :failed ->
        {:error, :internal}
    end
  end

  defp store(_source_key, :ignore), do: {:ok, :ignored}

  defp store(source_key, %CanonicalEvent{} = event) do
    Multi.new()
    |> Multi.run(:event, fn repo, _changes -> insert_event(repo, source_key, event) end)
    |> Multi.run(:job, fn _repo, %{event: inserted} -> enqueue(inserted) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: {:inserted, _id}}} ->
        {:ok, :accepted}

      {:ok, %{event: :duplicate}} ->
        {:ok, :duplicate}

      {:error, step, reason, _changes} ->
        Logger.error(
          "webhook persistence failed source_key=#{source_key} step=#{step} error=#{inspect(reason)}"
        )

        {:error, :internal}
    end
  end

  defp insert_event(repo, source_key, event) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      source: source_key,
      external_event_id: event.external_event_id,
      event_type: event.event_type,
      status: "received",
      payload: CanonicalEvent.to_map(event),
      inserted_at: now,
      updated_at: now
    }

    # `on_conflict: :nothing` + `returning` yields zero rows for a duplicate, which
    # is how we tell "already seen" apart from "new" without a race.
    case repo.insert_all(WebhookEvent, [row],
           on_conflict: :nothing,
           conflict_target: [:source, :external_event_id],
           returning: [:id]
         ) do
      {1, [%{id: id}]} -> {:ok, {:inserted, id}}
      {0, _} -> {:ok, :duplicate}
    end
  end

  defp enqueue({:inserted, id}), do: Oban.insert(EventWorker.new(%{webhook_event_id: id}))
  defp enqueue(:duplicate), do: {:ok, nil}

  # Runs an adapter callback with a timeout, converting any raise/throw/exit into
  # `:failed` after logging it with the `source_key`.
  defp call(source_key, callback, fun) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:raised, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case Task.yield(task, callback_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:raised, formatted}} ->
        Logger.error(
          "integration callback raised source_key=#{source_key} callback=#{callback} error=#{inspect(formatted)}",
          source_key: source_key
        )

        :failed

      nil ->
        Logger.error(
          "integration callback timed out source_key=#{source_key} callback=#{callback}",
          source_key: source_key
        )

        :failed

      {:exit, reason} ->
        Logger.error(
          "integration callback exited source_key=#{source_key} callback=#{callback} reason=#{inspect(reason)}",
          source_key: source_key
        )

        :failed
    end
  end

  defp unexpected(source_key, callback, value) do
    Logger.error(
      "integration callback returned an invalid value source_key=#{source_key} callback=#{callback} value=#{inspect(value)}",
      source_key: source_key
    )

    {:error, :internal}
  end

  # Credentials per source come from runtime config until the `integrations`
  # table exists (multi-tenancy spec); they are never hardcoded in source.
  defp credentials_for(source_key) do
    :notifiq |> Application.get_env(:integration_credentials, %{}) |> Map.get(source_key, %{})
  end

  defp callback_timeout, do: Application.get_env(:notifiq, :integration_callback_timeout, 5_000)
end
