defmodule NotifiqWeb.PainelLive.Creditos do
  @moduledoc """
  The credit statement (Spec 011, FR-15/16/17): the balance and every entry of the tenant's
  ledger, newest first, each with the balance right after it.

  The tenant is `current_scope`'s; the page cursor stays in the socket.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

  alias Notifiq.Accounts.Scope
  alias Notifiq.Mensageria
  alias NotifiqWeb.Format
  alias NotifiqWeb.Labels

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)
    {entries, cursor} = Mensageria.page_credit_transactions(tenant_id)

    socket =
      socket
      |> assign(:page_title, "Créditos")
      |> assign(:now, DateTime.utc_now())
      |> assign(:balance, Mensageria.credit_balance(tenant_id))
      |> assign(:cursor, cursor)
      |> stream_configure(:entries, dom_id: &"entry-#{&1.transaction.id}")
      |> stream(:entries, entries)

    {:ok, socket}
  end

  @impl true
  def handle_event("more", _params, %{assigns: %{cursor: nil}} = socket), do: {:noreply, socket}

  def handle_event("more", _params, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    {entries, cursor} =
      Mensageria.page_credit_transactions(tenant_id, cursor: socket.assigns.cursor)

    {:noreply, socket |> assign(:cursor, cursor) |> stream(:entries, entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:creditos}>
      <Layouts.page_header caption="Painel / Créditos" title="Créditos">
        Quando os créditos entraram e para onde foram.
      </Layouts.page_header>

      <div class="space-y-8">
        <section
          id="balance-card"
          class="reveal tex-grid relative flex flex-col gap-6 overflow-hidden rounded-2xl bg-hero p-6 text-hero-text shadow-card sm:flex-row sm:items-end sm:justify-between lg:p-8"
          style="--i: 1"
        >
          <div
            class="pointer-events-none absolute -right-16 -top-16 size-64 rounded-full opacity-30 blur-3xl"
            style="background: radial-gradient(circle, #c8f169 0%, transparent 70%)"
          />
          <div class="relative">
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.2em] text-white/60">
              Saldo atual
            </p>
            <p
              id="balance"
              class="mt-4 font-mono text-6xl font-semibold tabular-nums tracking-tighter text-volt sm:text-7xl"
            >
              {Format.number(@balance)}
            </p>
          </div>
          <p id="recharge-note" class="relative max-w-xs text-sm text-white/60">
            Para recarregar, fale com quem administra a plataforma.
          </p>
        </section>

        <section class="reveal space-y-3" style="--i: 2">
          <h2 class="text-sm font-semibold">Lançamentos</h2>

          <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-card">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-line bg-surface-2 font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-3">
                <tr>
                  <th scope="col" class="px-5 py-3 font-medium">Lançamento</th>
                  <th scope="col" class="px-5 py-3 text-right font-medium">Valor</th>
                  <th scope="col" class="hidden px-5 py-3 text-right font-medium sm:table-cell">
                    Saldo após
                  </th>
                  <th scope="col" class="hidden px-5 py-3 text-right font-medium md:table-cell">
                    Quando
                  </th>
                </tr>
              </thead>
              <tbody id="entries" phx-update="stream" class="divide-y divide-line">
                <tr id="entries-empty" class="hidden only:table-row">
                  <td colspan="4">
                    <.empty_state icon="hero-banknotes">
                      Nenhum lançamento ainda. Os créditos que entram e as mensagens que saem aparecem aqui.
                    </.empty_state>
                  </td>
                </tr>
                <tr
                  :for={{id, %{transaction: entry, balance_after: balance_after}} <- @streams.entries}
                  id={id}
                  class="transition-colors hover:bg-surface-2"
                >
                  <td class="px-5 py-3.5">
                    <p class="font-medium">{Labels.credit_reason(entry.reason)}</p>
                    <.link
                      :if={entry.message_log_id}
                      id={"entry-message-#{entry.id}"}
                      navigate={~p"/painel/mensagens/#{entry.message_log_id}"}
                      class="text-xs text-brand hover:underline"
                    >
                      Ver mensagem
                    </.link>
                  </td>
                  <td
                    id={"amount-#{entry.id}"}
                    class={[
                      "px-5 py-3.5 text-right font-mono font-semibold tabular-nums",
                      if(entry.amount < 0, do: "text-ink", else: "text-ok")
                    ]}
                  >
                    {Format.signed(entry.amount)}
                  </td>
                  <td
                    id={"balance-after-#{entry.id}"}
                    class="hidden px-5 py-3.5 text-right font-mono tabular-nums text-ink-2 sm:table-cell"
                  >
                    {Format.number(balance_after)}
                  </td>
                  <td
                    class="hidden px-5 py-3.5 text-right text-ink-2 md:table-cell"
                    title={Format.datetime(entry.inserted_at)}
                  >
                    {Format.relative_time(entry.inserted_at, @now)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@cursor} class="flex justify-center pt-2">
            <button
              id="load-more"
              type="button"
              phx-click="more"
              phx-disable-with="Carregando..."
              class="inline-flex items-center gap-2 rounded-lg border border-line bg-surface px-4 py-2.5 text-sm font-medium text-ink shadow-sm transition hover:bg-surface-2 active:scale-[0.99]"
            >
              <.icon name="hero-arrow-down" class="size-4" /> Carregar mais
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
