defmodule NotifiqWeb.PainelLive.Dashboard do
  @moduledoc """
  The merchant's summary page (Spec 010, FR-15): balance, what was sent in the last 30
  days, which events did not turn into a message, and the latest messages.

  Every query is filtered by the tenant of `current_scope`.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

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

  # Where the merchant can fix what a problem says, when there is such a place (Spec 011).
  @problem_paths %{"skipped_no_template" => "/painel/templates"}

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
        %{
          status: status,
          title: title,
          hint: hint,
          count: count,
          path: Map.get(@problem_paths, status)
        }
      end

    sent = Map.get(logs, "sent", 0)
    in_progress = Map.get(logs, "pending", 0) + Map.get(logs, "uncertain", 0)
    failed = Map.get(logs, "failed", 0) + Map.get(logs, "unconfirmed", 0)

    # Share of the finished sends that arrived; nothing to say until one has finished.
    rate = if sent + failed > 0, do: round(sent * 100 / (sent + failed))

    socket =
      socket
      |> assign(:page_title, "Resumo")
      |> assign(:now, now)
      |> assign(:window_days, @window_days)
      |> assign(:recent_limit, @recent_limit)
      |> assign(:balance, Mensageria.credit_balance(tenant_id))
      |> assign(:sent, sent)
      |> assign(:in_progress, in_progress)
      |> assign(:failed, failed)
      |> assign(:total, sent + in_progress + failed)
      |> assign(:rate, rate)
      |> assign(:problems, problems)
      |> stream(:messages, Mensageria.list_message_logs(tenant_id, limit: @recent_limit))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:resumo}>
      <Layouts.page_header caption={"Painel / Resumo / #{@window_days} dias"} title="Resumo">
        Como a loja {@current_scope.tenant.name} enviou mensagens nos últimos {@window_days} dias.
      </Layouts.page_header>

      <div class="space-y-8 lg:space-y-10">
        <section id="stats" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div
            id="stat-balance"
            class="reveal tex-grid relative flex flex-col justify-between overflow-hidden rounded-2xl bg-hero p-6 text-hero-text shadow-card sm:col-span-2 lg:row-span-2 lg:p-8"
            style="--i: 1"
          >
            <div
              class="pointer-events-none absolute -right-16 -top-16 size-64 rounded-full opacity-30 blur-3xl"
              style="background: radial-gradient(circle, #c8f169 0%, transparent 70%)"
            />
            <div class="relative flex items-center justify-between">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.2em] text-white/60">
                Saldo de créditos
              </p>
              <.icon name="hero-banknotes" class="size-5 text-volt" />
            </div>
            <div class="relative mt-10">
              <p class="font-mono text-6xl font-semibold tabular-nums tracking-tighter text-volt sm:text-7xl">
                {Format.number(@balance)}
              </p>
              <p class="mt-3 max-w-xs text-sm text-white/60">
                créditos disponíveis. Cada mensagem enviada usa o custo do seu template.
              </p>
              <.link
                id="link-creditos"
                navigate={~p"/painel/creditos"}
                class="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-volt transition hover:translate-x-0.5"
              >
                Ver extrato <.icon name="hero-arrow-right-micro" class="size-4" />
              </.link>
            </div>
          </div>

          <.stat
            id="stat-sent"
            index={2}
            label="Enviadas"
            value={Format.number(@sent)}
            icon="hero-paper-airplane"
          />
          <.stat
            id="stat-in-progress"
            index={3}
            label="Em andamento"
            value={Format.number(@in_progress)}
            icon="hero-clock"
          />
          <.stat
            id="stat-failed"
            index={4}
            label="Falhas ou sem confirmação"
            value={Format.number(@failed)}
            icon="hero-exclamation-triangle"
            tone={if(@failed > 0, do: :alert)}
            link={if(@failed > 0, do: ~p"/painel/mensagens?#{[situacao: "failed"]}")}
            link_id="link-failed"
          />
          <.stat
            id="stat-rate"
            index={5}
            label="Taxa de entrega"
            value={if(@rate, do: "#{@rate}%", else: "—")}
            icon="hero-check-badge"
            tone={if(@rate && @rate >= 95, do: :good)}
          />
        </section>

        <section
          id="distribution"
          class="reveal rounded-2xl border border-line bg-surface p-5 shadow-card sm:p-6"
          style="--i: 6"
        >
          <div class="flex items-baseline justify-between">
            <h2 class="text-sm font-semibold">Situação dos envios</h2>
            <p class="font-mono text-xs text-ink-3">{Format.number(@total)} no período</p>
          </div>

          <div
            :if={@total > 0}
            class="mt-4 flex h-2.5 w-full overflow-hidden rounded-full bg-surface-2"
            role="img"
            aria-label="Proporção de mensagens enviadas, em andamento e com falha"
          >
            <div class="bg-ok" style={"width: #{share(@sent, @total)}%"} />
            <div class="bg-brand" style={"width: #{share(@in_progress, @total)}%"} />
            <div class="bg-bad" style={"width: #{share(@failed, @total)}%"} />
          </div>
          <div :if={@total == 0} class="mt-4 h-2.5 w-full rounded-full bg-surface-2" />

          <div class="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-xs text-ink-2">
            <span class="flex items-center gap-2"><span class="size-2 rounded-full bg-ok"></span>
            Enviadas</span>
            <span class="flex items-center gap-2"><span class="size-2 rounded-full bg-brand"></span>
            Em andamento</span>
            <span class="flex items-center gap-2"><span class="size-2 rounded-full bg-bad"></span>
            Falhas</span>
          </div>
        </section>

        <section id="attention" class="reveal space-y-3" style="--i: 7">
          <h2 class="text-sm font-semibold">Eventos que não geraram envio</h2>

          <div
            :if={@problems == []}
            id="attention-empty"
            class="flex items-center gap-3 rounded-xl border border-line bg-ok-soft px-4 py-3.5 text-sm text-ok"
          >
            <.icon name="hero-check-circle" class="size-5 shrink-0" />
            Nenhum evento ficou sem envio nos últimos {@window_days} dias.
          </div>

          <ul
            :if={@problems != []}
            class="divide-y divide-line overflow-hidden rounded-xl border border-line bg-surface shadow-card"
          >
            <li
              :for={problem <- @problems}
              id={"problem-#{problem.status}"}
              class="flex items-start justify-between gap-4 border-l-[3px] border-l-warn px-4 py-3.5"
            >
              <div>
                <p class="text-sm font-semibold">{problem.title}</p>
                <p class="mt-0.5 text-[13px] text-ink-2">{problem.hint}</p>
                <.link
                  :if={problem.path}
                  id={"problem-link-#{problem.status}"}
                  navigate={problem.path}
                  class="mt-1.5 inline-flex items-center gap-1 text-[13px] font-medium text-brand hover:underline"
                >
                  Ir para os templates <.icon name="hero-arrow-right-micro" class="size-3.5" />
                </.link>
              </div>
              <span class="rounded-md bg-warn-soft px-2.5 py-1 font-mono text-sm font-semibold tabular-nums text-warn">
                {Format.number(problem.count)}
              </span>
            </li>
          </ul>
        </section>

        <section id="recent" class="reveal space-y-3" style="--i: 8">
          <div class="flex items-baseline justify-between">
            <h2 class="text-sm font-semibold">Mensagens recentes</h2>
            <p class="flex items-center gap-4 font-mono text-xs text-ink-3">
              últimas {@recent_limit}
              <.link
                id="link-mensagens"
                navigate={~p"/painel/mensagens"}
                class="font-sans text-sm font-medium text-brand hover:underline"
              >
                Ver todas
              </.link>
            </p>
          </div>

          <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-card">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-line bg-surface-2 font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-3">
                <tr>
                  <th scope="col" class="px-5 py-3 font-medium">Cliente</th>
                  <th scope="col" class="hidden px-5 py-3 font-medium sm:table-cell">Canal</th>
                  <th scope="col" class="px-5 py-3 font-medium">Situação</th>
                  <th scope="col" class="px-5 py-3 text-right font-medium">Quando</th>
                </tr>
              </thead>
              <tbody id="messages" phx-update="stream" class="divide-y divide-line">
                <tr id="messages-empty" class="hidden only:table-row">
                  <td colspan="4" class="px-5 py-14 text-center">
                    <.icon name="hero-inbox" class="mx-auto size-7 text-ink-3" />
                    <p class="mx-auto mt-3 max-w-sm text-sm text-ink-2">
                      Nenhuma mensagem ainda. Quando um pedido chegar de uma conta conectada, com um template ativo, a mensagem aparece aqui.
                    </p>
                  </td>
                </tr>
                <tr
                  :for={{id, log} <- @streams.messages}
                  id={id}
                  class="transition-colors hover:bg-surface-2"
                >
                  <td class="px-5 py-3.5 font-mono text-[13px]">
                    {Format.mask_phone(log.recipient)}
                  </td>
                  <td class="hidden px-5 py-3.5 sm:table-cell">
                    <span class="rounded bg-surface-2 px-1.5 py-0.5 font-mono text-[11px] font-medium uppercase text-ink-2 ring-1 ring-line">
                      {log.channel}
                    </span>
                  </td>
                  <td class="px-5 py-3.5"><.status_badge status={log.status} /></td>
                  <td class="px-5 py-3.5 text-right text-ink-2">
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

  # How much of the bar a part takes, with a decimal so small parts stay visible.
  defp share(_part, 0), do: 0
  defp share(part, total), do: Float.round(part * 100 / total, 1)

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :index, :integer, default: 0
  attr :tone, :atom, default: nil
  attr :link, :string, default: nil
  attr :link_id, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "reveal flex flex-col justify-between rounded-2xl border p-5 shadow-card transition duration-300 hover:-translate-y-0.5",
        case @tone do
          :alert -> "border-bad/30 bg-bad-soft"
          :good -> "border-ok/30 bg-ok-soft"
          _other -> "border-line bg-surface"
        end
      ]}
      style={"--i: #{@index}"}
    >
      <div class="flex items-start justify-between gap-3">
        <p class="text-[13px] font-medium text-ink-2">{@label}</p>
        <.icon
          name={@icon}
          class={[
            "size-[18px] shrink-0",
            case @tone do
              :alert -> "text-bad"
              :good -> "text-ok"
              _other -> "text-ink-3"
            end
          ]}
        />
      </div>
      <p class="mt-6 font-mono text-3xl font-semibold tabular-nums tracking-tight">{@value}</p>
      <.link
        :if={@link}
        id={@link_id}
        navigate={@link}
        class="mt-2 inline-flex items-center gap-1 text-[13px] font-medium text-bad hover:underline"
      >
        Ver mensagens <.icon name="hero-arrow-right-micro" class="size-3.5" />
      </.link>
    </div>
    """
  end
end
