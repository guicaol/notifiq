defmodule NotifiqWeb.PainelLive.Dashboard do
  @moduledoc """
  The merchant's summary page (Spec 010, FR-15): balance, what was sent in the last 30
  days, which events did not turn into a message, and the latest messages.

  Every query is filtered by the tenant of `current_scope`.
  """

  use NotifiqWeb, :live_view

  alias Notifiq.Accounts.Scope
  alias Notifiq.Mensageria
  alias NotifiqWeb.Format

  @window_days 30
  @recent_limit 10

  # Event outcomes that left the merchant without a message, in the order they are shown.
  @problem_events [
    {"insufficient_credits", "Sem créditos",
     "Chegaram quando o saldo não cobria o envio. Não são reenviados automaticamente."},
    {"render_failed", "Texto não gerado", "O template pede um dado que o evento não trouxe."},
    {"invalid_request", "Dados inválidos",
     "O telefone do cliente está ausente ou fora do formato."},
    {"skipped_no_template", "Sem template", "Não há template ativo para esse tipo de evento."}
  ]

  @status_labels %{
    "sent" => {"Enviada", :ok},
    "pending" => {"Na fila", :neutral},
    "uncertain" => {"Verificando", :neutral},
    "failed" => {"Falhou", :error},
    "unconfirmed" => {"Sem confirmação", :warn}
  }

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)
    now = DateTime.utc_now()
    since = DateTime.add(now, -@window_days, :day)

    logs = Mensageria.count_message_logs_by_status(tenant_id, since)
    events = Mensageria.count_webhook_events_by_status(tenant_id, since)

    problems =
      for {status, title, hint} <- @problem_events,
          count = Map.get(events, status, 0),
          count > 0 do
        %{status: status, title: title, hint: hint, count: count}
      end

    socket =
      socket
      |> assign(:page_title, "Resumo")
      |> assign(:now, now)
      |> assign(:window_days, @window_days)
      |> assign(:balance, Mensageria.credit_balance(tenant_id))
      |> assign(:sent, Map.get(logs, "sent", 0))
      |> assign(:in_progress, Map.get(logs, "pending", 0) + Map.get(logs, "uncertain", 0))
      |> assign(:failed, Map.get(logs, "failed", 0) + Map.get(logs, "unconfirmed", 0))
      |> assign(:problems, problems)
      |> stream(:messages, Mensageria.list_message_logs(tenant_id, limit: @recent_limit))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:resumo}>
      <div class="space-y-8">
        <header>
          <h1 class="text-2xl font-semibold tracking-tight">Resumo</h1>
          <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Os últimos {@window_days} dias da sua loja.
          </p>
        </header>

        <section id="stats" class="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <.stat
            id="stat-balance"
            label="Saldo de créditos"
            value={Format.number(@balance)}
            icon="hero-banknotes"
            tone={:brand}
          />
          <.stat
            id="stat-sent"
            label="Mensagens enviadas"
            value={Format.number(@sent)}
            icon="hero-paper-airplane"
          />
          <.stat
            id="stat-in-progress"
            label="Em andamento"
            value={Format.number(@in_progress)}
            icon="hero-clock"
          />
          <.stat
            id="stat-failed"
            label="Falhas ou sem confirmação"
            value={Format.number(@failed)}
            icon="hero-exclamation-triangle"
            tone={if(@failed > 0, do: :alert)}
          />
        </section>

        <section id="attention" class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
            Eventos que não geraram envio
          </h2>

          <div
            :if={@problems == []}
            id="attention-empty"
            class="flex items-center gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800 dark:border-emerald-500/20 dark:bg-emerald-500/10 dark:text-emerald-200"
          >
            <.icon name="hero-check-circle" class="size-5 shrink-0" />
            Nenhum evento ficou sem envio nos últimos {@window_days} dias.
          </div>

          <ul
            :if={@problems != []}
            class="divide-y divide-zinc-200 overflow-hidden rounded-xl border border-amber-200 bg-white dark:divide-zinc-800 dark:border-amber-500/30 dark:bg-zinc-900"
          >
            <li
              :for={problem <- @problems}
              id={"problem-#{problem.status}"}
              class="flex items-start justify-between gap-4 px-4 py-3"
            >
              <div>
                <p class="text-sm font-medium">{problem.title}</p>
                <p class="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">{problem.hint}</p>
              </div>
              <span class="rounded-full bg-amber-100 px-2.5 py-0.5 text-sm font-semibold tabular-nums text-amber-800 dark:bg-amber-500/15 dark:text-amber-200">
                {Format.number(problem.count)}
              </span>
            </li>
          </ul>
        </section>

        <section id="recent" class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
            Mensagens recentes
          </h2>

          <div class="overflow-hidden rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-zinc-200 bg-zinc-50 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
                <tr>
                  <th scope="col" class="px-4 py-2.5 font-medium">Cliente</th>
                  <th scope="col" class="hidden px-4 py-2.5 font-medium sm:table-cell">Canal</th>
                  <th scope="col" class="px-4 py-2.5 font-medium">Situação</th>
                  <th scope="col" class="px-4 py-2.5 text-right font-medium">Quando</th>
                </tr>
              </thead>
              <tbody
                id="messages"
                phx-update="stream"
                class="divide-y divide-zinc-100 dark:divide-zinc-800"
              >
                <tr id="messages-empty" class="hidden only:table-row">
                  <td
                    colspan="4"
                    class="px-4 py-10 text-center text-sm text-zinc-500 dark:text-zinc-400"
                  >
                    Nenhuma mensagem enviada ainda. Quando um pedido chegar de uma conta conectada, com um template ativo, a mensagem aparece aqui.
                  </td>
                </tr>
                <tr :for={{id, log} <- @streams.messages} id={id}>
                  <td class="px-4 py-3 font-mono text-xs">{Format.mask_phone(log.recipient)}</td>
                  <td class="hidden px-4 py-3 uppercase text-zinc-500 sm:table-cell dark:text-zinc-400">
                    {log.channel}
                  </td>
                  <td class="px-4 py-3"><.status_badge status={log.status} /></td>
                  <td class="px-4 py-3 text-right text-zinc-500 dark:text-zinc-400">
                    {Format.relative_time(log.inserted_at, @now)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :atom, default: nil

  defp stat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-xl border p-4 shadow-sm transition-shadow hover:shadow-md",
        case @tone do
          :brand ->
            "border-emerald-200 bg-emerald-50 dark:border-emerald-500/30 dark:bg-emerald-500/10"

          :alert ->
            "border-red-200 bg-red-50 dark:border-red-500/30 dark:bg-red-500/10"

          _other ->
            "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
        end
      ]}
    >
      <div class="flex items-center justify-between text-zinc-500 dark:text-zinc-400">
        <p class="text-xs font-medium">{@label}</p>
        <.icon name={@icon} class="size-4" />
      </div>
      <p class="mt-2 text-2xl font-semibold tabular-nums tracking-tight">{@value}</p>
    </div>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    {label, tone} = Map.get(@status_labels, assigns.status, {assigns.status, :neutral})
    assigns = assign(assigns, label: label, tone: tone)

    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
      case @tone do
        :ok -> "bg-emerald-100 text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-300"
        :error -> "bg-red-100 text-red-800 dark:bg-red-500/15 dark:text-red-300"
        :warn -> "bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-200"
        _neutral -> "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
      end
    ]}>
      {@label}
    </span>
    """
  end
end
