defmodule Notifiq.Mensageria.DispatchWorker do
  @moduledoc """
  Sends one reserved message off the request path and decides what happens next
  (Spec 007).

  It makes an attempt through `Notifiq.Mensageria.attempt_dispatch/2` and reads the state
  the log ends up in:

    * `sent` / `failed` — done (a permanent failure was already refunded)
    * `pending` (retryable failure) — try again later, or on the last attempt give up and
      refund
    * `uncertain` — the message may have gone out. It is **not** resent unless
      `:uncertain_resends` allows it, because resending can duplicate the SMS; instead the
      log is closed as `unconfirmed` and the credit stays spent

  The job holds only ids (`tenant_id`, `message_log_id`): the phone number and the text
  live in `message_logs`, not in `oban_jobs`. One active job per log (`unique`) keeps two
  attempts of the same message from running together.
  """

  use Oban.Worker,
    queue: :dispatch,
    max_attempts: 6,
    unique: [
      fields: [:worker, :args],
      keys: [:message_log_id],
      period: :infinity,
      states: :incomplete
    ]

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.Backoff
  alias Notifiq.Mensageria.DispatchSettings
  alias Notifiq.Mensageria.MessageLog

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "message_log_id" => log_id}} = job) do
    tenant_id
    |> attempt(log_id)
    |> react(job)
  rescue
    exception ->
      # A crash on the last attempt would leave the log pending and the credit stuck.
      if last_attempt?(job), do: close_after_crash(job.args)
      reraise exception, __STACKTRACE__
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Backoff.delay(attempt)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  # The module is swappable so tests can make the attempt itself blow up.
  defp attempt(tenant_id, log_id) do
    module = Application.get_env(:notifiq, :dispatch_attempt_module, Mensageria)
    module.attempt_dispatch(tenant_id, log_id)
  end

  defp react({:ok, %MessageLog{status: "sent"}}, _job), do: :ok
  defp react({:ok, %MessageLog{status: "failed"}}, _job), do: :ok

  defp react({:ok, %MessageLog{status: "pending"} = log}, job), do: retry_or_close(job, log)

  defp react({:ok, %MessageLog{status: "uncertain"} = log}, job) do
    if job.attempt <= DispatchSettings.get(:uncertain_resends),
      do: retry_or_close(job, log),
      else: close(log, :uncertain_not_resent)
  end

  defp react({:error, :already_final}, _job), do: :ok
  defp react({:error, :not_found}, _job), do: {:cancel, :message_log_not_found}
  defp react({:error, :invalid_outcome}, _job), do: {:error, :invalid_outcome}

  defp retry_or_close(job, log) do
    if last_attempt?(job),
      do: close(log, :retries_exhausted),
      else: {:error, "#{log.last_error_class}: #{log.last_error_reason}"}
  end

  # `give_up/2` refunds a pending log and keeps the credit of an uncertain one.
  defp close(log, reason) do
    case Mensageria.give_up(log, reason) do
      {:ok, _closed} -> {:cancel, reason}
      {:error, :already_final} -> :ok
      {:error, :not_found} -> {:cancel, :message_log_not_found}
    end
  end

  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  # Best effort: never hide the original exception behind a failure of the cleanup.
  defp close_after_crash(%{"tenant_id" => tenant_id, "message_log_id" => log_id}) do
    with %MessageLog{} = log <- Mensageria.get_message_log(tenant_id, log_id) do
      Mensageria.give_up(log, :worker_crashed)
    end
  rescue
    _cleanup_failure -> :ok
  end
end
