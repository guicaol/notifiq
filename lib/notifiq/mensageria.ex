defmodule Notifiq.Mensageria do
  @moduledoc """
  Core of the messaging domain (Spec 006): one dispatch per received event, charged
  exactly once, never overdrawing a tenant.

  The flow is `reserve/1` (log + debit + ledger in one transaction) -> `attempt_dispatch/2`
  (send through `Notifiq.Channels.Dispatcher`, record the outcome) -> a final state. A
  permanent failure refunds the reserved credit; an uncertain one keeps it, because the
  message may have gone out.

  Every function takes the `tenant_id` and filters by it (Constitution, principle 7).
  Nothing here names a source or a provider: the provider is just the key the caller passes.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Notifiq.Channels.Dispatcher
  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria.Credits
  alias Notifiq.Mensageria.CreditTransaction
  alias Notifiq.Mensageria.DispatchWorker
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo
  alias Notifiq.Tenants.Tenant

  @type reserve_error ::
          :insufficient_credits
          | :invalid_request
          | :unknown_event
          | :unknown_tenant
          | :conflict

  # --- reserving a dispatch --------------------------------------------------------

  @doc """
  Reserves the dispatch of one received event.

  Required keys: `:tenant_id`, `:webhook_event_id`, `:provider` (key string), `:channel`,
  `:recipient` (E.164) and `:body`. Optional: `:cost` (default 1).

  Returns `{:ok, log}` for a new reservation, `{:duplicate, log}` when the event already
  has one (nothing is charged again), or `{:error, reason}`.
  """
  @spec reserve(map()) ::
          {:ok, MessageLog.t()} | {:duplicate, MessageLog.t()} | {:error, reserve_error()}
  def reserve(attrs) when is_map(attrs) do
    with {:ok, request} <- validate_request(attrs) do
      request
      |> reserve_multi()
      |> Repo.transaction()
      |> reserve_result(request)
    end
  end

  def reserve(_other), do: {:error, :invalid_request}

  @doc """
  `reserve/1` plus the `Notifiq.Mensageria.DispatchWorker` job, in the same transaction
  (Spec 007, FR-1): either the dispatch is reserved *and* scheduled, or nothing happened.
  There is no window where credit is held for a message nobody will send.

  A duplicate gets no second job: the first request's job is the only one. The job's args
  hold only ids, never the phone number or the text.
  """
  @spec request_dispatch(map()) ::
          {:ok, MessageLog.t()}
          | {:duplicate, MessageLog.t()}
          | {:error, reserve_error() | :enqueue_failed}
  def request_dispatch(attrs) when is_map(attrs) do
    with {:ok, request} <- validate_request(attrs) do
      request
      |> reserve_multi()
      |> Oban.insert(:job, fn %{log: log} ->
        DispatchWorker.new(%{tenant_id: log.tenant_id, message_log_id: log.id})
      end)
      |> Repo.transaction()
      |> reserve_result(request)
    end
  end

  def request_dispatch(_other), do: {:error, :invalid_request}

  defp reserve_multi(request) do
    Multi.new()
    |> Multi.run(:tenant, fn repo, _changes -> ensure_tenant(repo, request) end)
    |> Multi.run(:event, fn repo, _changes -> ensure_event(repo, request) end)
    |> Multi.run(:log, fn repo, _changes -> insert_log(repo, request) end)
    |> Multi.run(:debit, fn repo, %{log: log} ->
      Credits.debit(repo, log.tenant_id, log.cost)
    end)
    |> Multi.run(:ledger, fn repo, %{log: log} ->
      Credits.record(repo, %{
        tenant_id: log.tenant_id,
        message_log_id: log.id,
        amount: -log.cost,
        reason: "dispatch"
      })
    end)
  end

  defp validate_request(attrs) do
    with {:ok, tenant_id} <- cast_uuid(attrs[:tenant_id]),
         {:ok, event_id} <- cast_uuid(attrs[:webhook_event_id]),
         {:ok, channel} <- cast_channel(attrs[:channel]),
         true <- non_blank?(attrs[:provider]),
         cost when is_integer(cost) and cost >= 1 <- Map.get(attrs, :cost, 1),
         message = %OutboundMessage{
           channel: channel,
           to: attrs[:recipient],
           body: attrs[:body],
           idempotency_key: event_id
         },
         :ok <- OutboundMessage.validate(message) do
      {:ok,
       %{
         tenant_id: tenant_id,
         webhook_event_id: event_id,
         provider: attrs[:provider],
         channel: Atom.to_string(channel),
         recipient: attrs[:recipient],
         body: attrs[:body],
         cost: cost
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_value), do: :error

  # Never `String.to_atom/1` on input: match against the known channels instead.
  defp cast_channel(channel) when is_atom(channel) and not is_nil(channel) do
    if channel in OutboundMessage.channels(), do: {:ok, channel}, else: :error
  end

  defp cast_channel(channel) when is_binary(channel) do
    case Enum.find(OutboundMessage.channels(), &(Atom.to_string(&1) == channel)) do
      nil -> :error
      known -> {:ok, known}
    end
  end

  defp cast_channel(_channel), do: :error

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  # The event must belong to the tenant asking to dispatch it (Spec 008, FR-9). Another
  # tenant's event is reported exactly like a missing one, so its existence isn't revealed.
  defp ensure_event(repo, %{webhook_event_id: id, tenant_id: tenant_id}) do
    if repo.exists?(from e in WebhookEvent, where: e.id == ^id and e.tenant_id == ^tenant_id),
      do: {:ok, :found},
      else: {:error, :unknown_event}
  end

  defp ensure_tenant(repo, %{tenant_id: id}) do
    if Credits.tenant_exists?(repo, id), do: {:ok, :found}, else: {:error, :unknown_tenant}
  end

  # `ON CONFLICT DO NOTHING` returns zero rows for a duplicate. A concurrent insert of the
  # same event blocks on the unique index until the other transaction ends, so exactly one
  # of them gets the row.
  defp insert_log(repo, request) do
    now = DateTime.utc_now()

    row =
      Map.merge(request, %{
        id: Ecto.UUID.generate(),
        status: "pending",
        attempts: 0,
        inserted_at: now,
        updated_at: now
      })

    case repo.insert_all(MessageLog, [row],
           on_conflict: :nothing,
           conflict_target: [:webhook_event_id],
           returning: true
         ) do
      {1, [%MessageLog{} = log]} -> {:ok, log}
      {0, _} -> {:error, :duplicate}
    end
  end

  defp reserve_result({:ok, %{log: log}}, _request), do: {:ok, log}
  defp reserve_result({:error, :log, :duplicate, _changes}, request), do: existing_log(request)

  defp reserve_result({:error, step, reason, _changes}, _request)
       when step in [:event, :tenant, :debit], do: {:error, reason}

  defp reserve_result({:error, :ledger, _changeset, _changes}, _request), do: {:error, :conflict}

  defp reserve_result({:error, :job, _changeset, _changes}, _request),
    do: {:error, :enqueue_failed}

  # The duplicate is reported only to the tenant that owns it: another tenant's log must
  # not be revealed.
  defp existing_log(%{tenant_id: tenant_id, webhook_event_id: event_id}) do
    log =
      Repo.one(
        from l in MessageLog, where: l.tenant_id == ^tenant_id and l.webhook_event_id == ^event_id
      )

    if log, do: {:duplicate, log}, else: {:error, :conflict}
  end

  # --- recording what happened -----------------------------------------------------

  @doc """
  Records the result of a send attempt (the return value of
  `Notifiq.Channels.Dispatcher.dispatch/2`) and moves the log accordingly.

  Allowed only from `pending` or `uncertain`. A permanent failure refunds the credit, in
  the same transaction, at most once.
  """
  @spec record_outcome(MessageLog.t(), Dispatcher.result()) ::
          {:ok, MessageLog.t()} | {:error, :already_final | :not_found | :invalid_outcome}
  def record_outcome(%MessageLog{} = log, result) do
    with {:ok, {status, refund?, changes}} <- outcome_change(result) do
      Multi.new()
      |> Multi.run(:log, fn repo, _changes ->
        case move(repo, log, ["pending", "uncertain"], status, changes, true) do
          {:ok, updated} -> {:ok, updated}
          {:error, :no_match} -> {:error, missing_reason(repo, log)}
        end
      end)
      |> Multi.run(:refund, fn repo, %{log: updated} -> maybe_refund(repo, updated, refund?) end)
      |> Repo.transaction()
      |> transition_result()
    end
  end

  defp outcome_change({:ok, %SendReceipt{provider_message_id: id}}) do
    {:ok,
     {"sent", false, [provider_message_id: id, last_error_class: nil, last_error_reason: nil]}}
  end

  defp outcome_change({:error, {class, reason}})
       when class in [:retryable, :uncertain, :permanent] and is_atom(reason) do
    status = %{retryable: "pending", uncertain: "uncertain", permanent: "failed"}[class]

    {:ok,
     {status, class == :permanent,
      [last_error_class: Atom.to_string(class), last_error_reason: Atom.to_string(reason)]}}
  end

  defp outcome_change(_other), do: {:error, :invalid_outcome}

  @doc """
  Closes a log the worker has given up on: `pending` -> `failed` (credit refunded) and
  `uncertain` -> `unconfirmed` (credit kept, for manual review). Not counted as an attempt.
  """
  @spec give_up(MessageLog.t(), atom()) ::
          {:ok, MessageLog.t()} | {:error, :already_final | :not_found}
  def give_up(%MessageLog{} = log, reason) when is_atom(reason) do
    reason = Atom.to_string(reason)

    Multi.new()
    |> Multi.run(:log, fn repo, _changes -> close(repo, log, reason) end)
    |> Multi.run(:refund, fn repo, %{log: {updated, refund?}} ->
      maybe_refund(repo, updated, refund?)
    end)
    |> Multi.run(:result, fn _repo, %{log: {updated, _refund?}} -> {:ok, updated} end)
    |> Repo.transaction()
    |> case do
      {:ok, %{result: updated}} -> {:ok, updated}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp close(repo, log, reason) do
    changes = [last_error_class: "gave_up", last_error_reason: reason]

    case move(repo, log, ["pending"], "failed", changes, false) do
      {:ok, updated} ->
        {:ok, {updated, true}}

      {:error, :no_match} ->
        case move(repo, log, ["uncertain"], "unconfirmed", changes, false) do
          {:ok, updated} -> {:ok, {updated, false}}
          {:error, :no_match} -> {:error, missing_reason(repo, log)}
        end
    end
  end

  # The state change is a conditional UPDATE, so of two racing calls only one matches.
  defp move(repo, log, from_statuses, status, changes, count_attempt?) do
    query =
      from l in MessageLog,
        where: l.id == ^log.id and l.tenant_id == ^log.tenant_id and l.status in ^from_statuses,
        select: l

    updates =
      [set: [status: status, updated_at: DateTime.utc_now()] ++ changes] ++
        if(count_attempt?, do: [inc: [attempts: 1]], else: [])

    case repo.update_all(query, updates) do
      {1, [%MessageLog{} = updated]} -> {:ok, updated}
      {0, _} -> {:error, :no_match}
    end
  end

  defp missing_reason(repo, log) do
    scoped = from l in MessageLog, where: l.id == ^log.id and l.tenant_id == ^log.tenant_id
    if repo.exists?(scoped), do: :already_final, else: :not_found
  end

  defp maybe_refund(_repo, _log, false), do: {:ok, nil}

  defp maybe_refund(repo, %MessageLog{} = log, true) do
    with {:ok, :credited} <- Credits.credit(repo, log.tenant_id, log.cost) do
      Credits.record(repo, %{
        tenant_id: log.tenant_id,
        message_log_id: log.id,
        amount: log.cost,
        reason: "refund"
      })
    end
  end

  defp transition_result({:ok, %{log: updated}}), do: {:ok, updated}

  defp transition_result({:error, _step, reason, _changes}), do: {:error, reason}

  # --- sending ---------------------------------------------------------------------

  @doc """
  Makes one send attempt for a log and records the outcome.

  Reloads the log (scoped by tenant) and refuses final ones without calling any provider,
  so a delivered message is never sent twice. The provider receives the log id as its
  `idempotency_key`. Returns the updated log: its `status` tells the caller what happened
  (`sent`, `pending` to retry, `uncertain`, `failed`).

  Keeping two attempts of the same log from running at once is the caller's job (the
  worker uses a unique job per log): no database lock is held during the HTTP call.
  """
  @spec attempt_dispatch(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageLog.t()} | {:error, :not_found | :already_final | :invalid_outcome}
  def attempt_dispatch(tenant_id, message_log_id) do
    case get_message_log(tenant_id, message_log_id) do
      nil ->
        {:error, :not_found}

      %MessageLog{} = log ->
        if MessageLog.final?(log) do
          {:error, :already_final}
        else
          result = Dispatcher.dispatch(log.provider, to_outbound_message(log))
          record_outcome(log, result)
        end
    end
  end

  @doc "Builds the provider-facing message for a log. The log id is the idempotency key."
  @spec to_outbound_message(MessageLog.t()) :: OutboundMessage.t()
  def to_outbound_message(%MessageLog{} = log) do
    %OutboundMessage{
      tenant_id: log.tenant_id,
      channel: Enum.find(OutboundMessage.channels(), &(Atom.to_string(&1) == log.channel)),
      to: log.recipient,
      body: log.body,
      idempotency_key: log.id
    }
  end

  # --- credits ---------------------------------------------------------------------

  @doc "Adds credits to a tenant, with its ledger entry, atomically."
  @spec add_credits(Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, integer()} | {:error, :invalid_amount | :invalid_reason | :unknown_tenant}
  def add_credits(tenant_id, amount, reason \\ "purchase")

  def add_credits(tenant_id, amount, reason)
      when is_integer(amount) and amount > 0 and reason in ["purchase", "adjustment"] do
    Multi.new()
    |> Multi.run(:credit, fn repo, _changes -> Credits.credit(repo, tenant_id, amount) end)
    |> Multi.run(:ledger, fn repo, _changes ->
      Credits.record(repo, %{tenant_id: tenant_id, amount: amount, reason: reason})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, credit_balance(tenant_id)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def add_credits(_tenant_id, amount, _reason) when not is_integer(amount) or amount <= 0,
    do: {:error, :invalid_amount}

  def add_credits(_tenant_id, _amount, _reason), do: {:error, :invalid_reason}

  # --- tenant-scoped reads ---------------------------------------------------------

  @doc "The tenant's balance, or `nil` when the tenant doesn't exist."
  @spec credit_balance(Ecto.UUID.t()) :: integer() | nil
  def credit_balance(tenant_id) do
    Repo.one(from t in Tenant, where: t.id == ^tenant_id, select: t.credit_balance)
  end

  @doc "A log of this tenant, or `nil` — also when the id belongs to another tenant."
  @spec get_message_log(Ecto.UUID.t(), Ecto.UUID.t()) :: MessageLog.t() | nil
  def get_message_log(tenant_id, id) do
    Repo.one(from l in MessageLog, where: l.tenant_id == ^tenant_id and l.id == ^id)
  end

  @doc "The tenant's logs, newest first."
  @spec list_message_logs(Ecto.UUID.t(), keyword()) :: [MessageLog.t()]
  def list_message_logs(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from l in MessageLog,
        where: l.tenant_id == ^tenant_id,
        order_by: [desc: l.inserted_at, desc: l.id],
        limit: ^limit
    )
  end

  @doc "The tenant's ledger, newest first (by the ledger's own sequence, which never ties)."
  @spec list_credit_transactions(Ecto.UUID.t(), keyword()) :: [CreditTransaction.t()]
  def list_credit_transactions(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.all(
      from c in CreditTransaction,
        where: c.tenant_id == ^tenant_id,
        order_by: [desc: c.seq],
        limit: ^limit
    )
  end

  @active_job_states ["available", "scheduled", "executing", "retryable"]

  @doc """
  The tenant's unfinished logs (`pending` or `uncertain`) untouched since `cutoff` that no
  active dispatch job is going to pick up. Used by `Notifiq.Mensageria.Sweeper`.

  A log whose retry is merely scheduled far ahead has an active job and is not returned.
  """
  @spec list_stale_logs(Ecto.UUID.t(), DateTime.t(), keyword()) :: [MessageLog.t()]
  def list_stale_logs(tenant_id, %DateTime{} = cutoff, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    worker = inspect(DispatchWorker)

    Repo.all(
      from l in MessageLog,
        as: :log,
        where:
          l.tenant_id == ^tenant_id and l.status in ["pending", "uncertain"] and
            l.updated_at < ^cutoff,
        where:
          not exists(
            from j in Oban.Job,
              where:
                j.worker == ^worker and j.state in ^@active_job_states and
                  fragment("?->>'message_log_id' = ?::text", j.args, parent_as(:log).id),
              select: 1
          ),
        order_by: [asc: l.updated_at],
        limit: ^limit
    )
  end

  @doc "A received event of this tenant, or `nil` — also when the id belongs to another tenant."
  @spec get_webhook_event(Ecto.UUID.t(), Ecto.UUID.t()) :: WebhookEvent.t() | nil
  def get_webhook_event(tenant_id, id) do
    Repo.one(from e in WebhookEvent, where: e.tenant_id == ^tenant_id and e.id == ^id)
  end

  @doc "The tenant's received events, newest first."
  @spec list_webhook_events(Ecto.UUID.t(), keyword()) :: [WebhookEvent.t()]
  def list_webhook_events(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from e in WebhookEvent,
        where: e.tenant_id == ^tenant_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  Records what became of a received event (Spec 009). It only moves an event out of
  `received`, so a repeated run of the worker can't overwrite an earlier outcome, and it
  only touches the tenant's own events.
  """
  @spec update_event_status(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          :ok | {:error, :invalid_status}
  def update_event_status(tenant_id, event_id, status) do
    if status in WebhookEvent.statuses() and status != "received" do
      Repo.update_all(
        from(e in WebhookEvent,
          where: e.id == ^event_id and e.tenant_id == ^tenant_id and e.status == "received"
        ),
        set: [status: status, updated_at: DateTime.utc_now()]
      )

      :ok
    else
      {:error, :invalid_status}
    end
  end
end
