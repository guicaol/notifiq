defmodule NotifiqWeb.PainelLive.Mensagens do
  @moduledoc """
  The merchant's message history (Spec 011, FR-11/12): every message the platform sent on
  the tenant's behalf, newest first, 25 at a time, with a filter by situation.

  The tenant is `current_scope`'s. The page cursor lives in the socket and never comes from
  the browser; the only input from the URL is the filter, checked against a fixed list.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

  alias Notifiq.Accounts.Scope
  alias Notifiq.Mensageria
  alias NotifiqWeb.Format
  alias NotifiqWeb.Labels

  # The same three bands the summary shows. Anything else in the URL means "all".
  @filters [
    {"all", "Todas", nil},
    {"sent", "Enviadas", ["sent"]},
    {"in_progress", "Em andamento", ["pending", "uncertain"]},
    {"failed", "Falhas", ["failed", "unconfirmed"]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Mensagens")
      |> assign(:filters, Enum.map(@filters, fn {key, label, _statuses} -> {key, label} end))
      |> assign(:filter, "all")
      |> assign(:cursor, nil)
      |> assign(:now, DateTime.utc_now())
      |> stream(:messages, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = filter_key(params["situacao"])
    {logs, cursor} = fetch(socket, filter, nil)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:cursor, cursor)
     |> assign(:now, DateTime.utc_now())
     |> stream(:messages, logs, reset: true)}
  end

  @impl true
  def handle_event("more", _params, %{assigns: %{cursor: nil}} = socket), do: {:noreply, socket}

  def handle_event("more", _params, socket) do
    {logs, cursor} = fetch(socket, socket.assigns.filter, socket.assigns.cursor)

    {:noreply, socket |> assign(:cursor, cursor) |> stream(:messages, logs)}
  end

  defp fetch(socket, filter, cursor) do
    {_key, _label, statuses} = List.keyfind(@filters, filter, 0)

    Mensageria.page_message_logs(Scope.tenant_id(socket.assigns.current_scope),
      statuses: statuses,
      cursor: cursor
    )
  end

  defp filter_key(key) when is_binary(key) do
    if List.keymember?(@filters, key, 0), do: key, else: "all"
  end

  defp filter_key(_other), do: "all"

  defp filter_path("all"), do: ~p"/painel/mensagens"
  defp filter_path(key), do: ~p"/painel/mensagens?#{[situacao: key]}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:mensagens}>
      <Layouts.page_header caption="Painel / Mensagens" title="Mensagens">
        Cada mensagem enviada em nome da loja {@current_scope.tenant.name}, da mais recente para a mais antiga.
      </Layouts.page_header>

      <div class="space-y-5">
        <nav
          id="message-filters"
          class="reveal -mx-1 flex gap-1 overflow-x-auto px-1"
          style="--i: 1"
          aria-label="Filtrar por situação"
        >
          <.link
            :for={{key, label} <- @filters}
            id={"filter-#{key}"}
            patch={filter_path(key)}
            aria-current={if(@filter == key, do: "true")}
            class={[
              "shrink-0 rounded-full px-3.5 py-1.5 text-sm font-medium transition-colors duration-200",
              if(@filter == key,
                do: "bg-chrome text-white",
                else: "text-ink-2 ring-1 ring-line hover:bg-surface-2 hover:text-ink"
              )
            ]}
          >
            {label}
          </.link>
        </nav>

        <div
          class="reveal overflow-hidden rounded-2xl border border-line bg-surface shadow-card"
          style="--i: 2"
        >
          <table class="w-full text-left text-sm">
            <thead class="border-b border-line bg-surface-2 font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-3">
              <tr>
                <th scope="col" class="px-5 py-3 font-medium">Cliente</th>
                <th scope="col" class="hidden px-5 py-3 font-medium sm:table-cell">Canal</th>
                <th scope="col" class="px-5 py-3 font-medium">Situação</th>
                <th scope="col" class="hidden px-5 py-3 text-right font-medium md:table-cell">
                  Créditos
                </th>
                <th scope="col" class="px-5 py-3 text-right font-medium">Quando</th>
              </tr>
            </thead>
            <tbody id="messages" phx-update="stream" class="divide-y divide-line">
              <tr id="messages-empty" class="hidden only:table-row">
                <td colspan="5">
                  <.empty_state icon="hero-inbox">
                    <%= if @filter == "all" do %>
                      Nenhuma mensagem ainda. Quando um pedido chegar de uma conta conectada, com um template ativo, a mensagem aparece aqui.
                    <% else %>
                      Nenhuma mensagem nesta situação.
                    <% end %>
                  </.empty_state>
                </td>
              </tr>
              <tr
                :for={{id, log} <- @streams.messages}
                id={id}
                class="cursor-pointer transition-colors hover:bg-surface-2"
                phx-click={JS.navigate(~p"/painel/mensagens/#{log.id}")}
              >
                <td class="px-5 py-3.5 font-mono text-[13px]">
                  <.link
                    id={"open-#{log.id}"}
                    navigate={~p"/painel/mensagens/#{log.id}"}
                    class="hover:underline"
                  >
                    {Format.mask_phone(log.recipient)}
                  </.link>
                </td>
                <td class="hidden px-5 py-3.5 sm:table-cell">
                  <span class="rounded bg-surface-2 px-1.5 py-0.5 font-mono text-[11px] font-medium uppercase text-ink-2 ring-1 ring-line">
                    {Labels.channel(log.channel)}
                  </span>
                </td>
                <td class="px-5 py-3.5"><.status_badge status={log.status} /></td>
                <td class="hidden px-5 py-3.5 text-right font-mono tabular-nums text-ink-2 md:table-cell">
                  {Format.number(log.cost)}
                </td>
                <td class="px-5 py-3.5 text-right text-ink-2" title={Format.datetime(log.inserted_at)}>
                  {Format.relative_time(log.inserted_at, @now)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@cursor} class="flex justify-center">
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
      </div>
    </Layouts.app>
    """
  end
end
