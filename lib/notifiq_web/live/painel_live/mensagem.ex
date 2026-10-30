defmodule NotifiqWeb.PainelLive.Mensagem do
  @moduledoc """
  One message of the tenant in full (Spec 011, FR-13/14): what was sent, what became of it
  and what it cost.

  The id in the URL is cast and looked up **inside the tenant**: another tenant's message,
  a missing one and a malformed id all end the same way, with "not found". The recipient
  stays masked, and neither the source's event id nor the raw payload is shown.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

  alias Notifiq.Accounts.Scope
  alias Notifiq.Integrations.Registry
  alias Notifiq.Mensageria
  alias NotifiqWeb.Format
  alias NotifiqWeb.Labels

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    case find(tenant_id, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Mensagem não encontrada.")
         |> push_navigate(to: ~p"/painel/mensagens")}

      log ->
        event = Mensageria.get_webhook_event(tenant_id, log.webhook_event_id)

        socket =
          socket
          |> assign(:page_title, "Mensagem")
          |> assign(:now, DateTime.utc_now())
          |> assign(:log, log)
          |> assign(:event_label, event && Labels.event_type(event.event_type))
          |> assign(:source_name, event && source_name(event.source))
          |> assign(:entries, Mensageria.list_credit_transactions_for_log(tenant_id, log.id))

        {:ok, socket}
    end
  end

  defp find(tenant_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Mensageria.get_message_log(tenant_id, uuid)
      :error -> nil
    end
  end

  # The name comes from the adapter; a source that is no longer registered shows its key.
  defp source_name(key) do
    Enum.find_value(Registry.describe_all(), key, fn source ->
      if source.key == key, do: source.name
    end)
  end

  defp failed?(log), do: log.status in ["failed", "unconfirmed"]

  defp problem_title(%{status: "failed"}), do: "Por que não foi enviada"
  defp problem_title(%{status: "unconfirmed"}), do: "Envio sem confirmação"
  defp problem_title(_log), do: "Última tentativa"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:mensagens}>
      <.link
        id="back-to-messages"
        navigate={~p"/painel/mensagens"}
        class="reveal mb-5 inline-flex items-center gap-1.5 text-sm font-medium text-ink-2 transition-colors hover:text-ink"
        style="--i: 0"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Todas as mensagens
      </.link>

      <Layouts.page_header caption="Painel / Mensagens / Detalhe" title="Mensagem">
        Enviada para {Format.mask_phone(@log.recipient)} {Format.relative_time(
          @log.inserted_at,
          @now
        )}.
      </Layouts.page_header>

      <div class="grid gap-6 lg:grid-cols-[1.4fr_1fr]">
        <div class="space-y-6">
          <section class="reveal space-y-3" style="--i: 1">
            <h2 class="text-sm font-semibold">Texto enviado</h2>
            <.bubble
              id="message-body"
              caption={"#{Labels.channel(@log.channel)} para #{Format.mask_phone(@log.recipient)}"}
              text={@log.body}
            />
          </section>

          <section
            :if={failed?(@log) or @log.last_error_reason}
            id="message-problem"
            class={[
              "reveal rounded-2xl border p-5",
              if(failed?(@log),
                do: "border-bad/30 bg-bad-soft",
                else: "border-line bg-surface-2"
              )
            ]}
            style="--i: 2"
          >
            <h2 class="flex items-center gap-2 text-sm font-semibold">
              <.icon
                name="hero-exclamation-triangle"
                class={["size-4", if(failed?(@log), do: "text-bad", else: "text-ink-3")]}
              />
              {problem_title(@log)}
            </h2>
            <p id="failure-reason" class="mt-2 text-sm text-ink">
              {Labels.failure_reason(@log.last_error_reason) || "O envio não foi concluído."}
            </p>
            <p
              :if={Labels.credit_outcome(@log.status)}
              id="credit-outcome"
              class="mt-1 text-sm text-ink-2"
            >
              {Labels.credit_outcome(@log.status)}
            </p>
          </section>
        </div>

        <div class="space-y-6">
          <section class="reveal space-y-3" style="--i: 2">
            <h2 class="text-sm font-semibold">Detalhes</h2>
            <dl
              id="message-details"
              class="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-surface text-sm shadow-card"
            >
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Situação</dt>
                <dd><.status_badge status={@log.status} /></dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Destinatário</dt>
                <dd class="font-mono text-[13px]">{Format.mask_phone(@log.recipient)}</dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Como foi enviada</dt>
                <dd class="font-mono text-[13px]">{Labels.delivery(@log.provider, @log.channel)}</dd>
              </div>
              <div :if={@event_label} class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Evento de origem</dt>
                <dd class="text-right">
                  {@event_label}
                  <span class="block text-xs text-ink-3">{@source_name}</span>
                </dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Créditos</dt>
                <dd class="font-mono tabular-nums">{Format.number(@log.cost)}</dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Tentativas</dt>
                <dd class="font-mono tabular-nums">{Format.number(@log.attempts)}</dd>
              </div>
              <div
                :if={@log.provider_message_id}
                class="flex items-center justify-between gap-4 px-5 py-3"
              >
                <dt class="shrink-0 text-ink-2">Código no provedor</dt>
                <dd class="min-w-0 truncate font-mono text-xs">{@log.provider_message_id}</dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Criada em</dt>
                <dd class="font-mono text-xs">{Format.datetime(@log.inserted_at)}</dd>
              </div>
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <dt class="text-ink-2">Atualizada em</dt>
                <dd class="font-mono text-xs">{Format.datetime(@log.updated_at)}</dd>
              </div>
            </dl>
          </section>

          <section class="reveal space-y-3" style="--i: 3">
            <h2 class="text-sm font-semibold">Créditos desta mensagem</h2>
            <ul
              id="message-ledger"
              class="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-surface text-sm shadow-card"
            >
              <li :if={@entries == []} id="message-ledger-empty" class="px-5 py-4 text-ink-2">
                Nenhum lançamento.
              </li>
              <li
                :for={entry <- @entries}
                id={"ledger-#{entry.id}"}
                class="flex items-center justify-between gap-4 px-5 py-3"
              >
                <span>
                  {Labels.credit_reason(entry.reason)}
                  <span class="block text-xs text-ink-3">{Format.datetime(entry.inserted_at)}</span>
                </span>
                <span class={[
                  "font-mono font-semibold tabular-nums",
                  if(entry.amount < 0, do: "text-ink", else: "text-ok")
                ]}>
                  {Format.signed(entry.amount)}
                </span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
