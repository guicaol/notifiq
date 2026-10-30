defmodule NotifiqWeb.PainelLive.Templates do
  @moduledoc """
  The merchant's message templates, one card per type of event (Spec 011, FR-4/10): the
  active template with its text as the customer would read it, the ones that are switched
  off, and a shortcut to write the missing ones.

  The tenant is `current_scope`'s. The only identifier the browser sends is a template id,
  cast and then looked up inside the tenant by `Notifiq.Templates`.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

  alias Notifiq.Accounts.Scope
  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Templates
  alias NotifiqWeb.Format
  alias NotifiqWeb.Labels

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Templates") |> load()}
  end

  @impl true
  def handle_event("activate", %{"id" => id}, socket) do
    case change(socket, id, &Templates.activate_template/2) do
      {:ok, _template} ->
        {:noreply, socket |> put_flash(:info, "Template ativado.") |> load()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Já existe um template ativo para este tipo de evento. Desative o atual antes."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Template não encontrado.")}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    case change(socket, id, &Templates.deactivate_template/2) do
      {:ok, _template} ->
        {:noreply, socket |> put_flash(:info, "Template desativado.") |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Template não encontrado.")}
    end
  end

  # A malformed id would raise in the query; it is just as "not found" as an unknown one.
  defp change(socket, id, fun) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> fun.(tenant_id, uuid)
      :error -> {:error, :not_found}
    end
  end

  # One entry per known event type: bounded by `EventTypes`, so a plain list is enough.
  defp load(socket) do
    by_type =
      socket.assigns.current_scope
      |> Scope.tenant_id()
      |> Templates.list_templates()
      |> Enum.group_by(& &1.event_type)

    groups =
      for type <- EventTypes.all() do
        {active, inactive} = by_type |> Map.get(type, []) |> Enum.split_with(& &1.active)
        active = List.first(active)
        %{type: type, active: active, inactive: inactive, preview: active && preview_text(active)}
      end

    assign(socket, :groups, groups)
  end

  defp preview_text(template) do
    case Templates.preview(template.body) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:templates}>
      <Layouts.page_header caption="Painel / Templates" title="Templates">
        O texto que o cliente recebe para cada tipo de evento. Sem template ativo, o evento chega mas nenhuma mensagem sai.
      </Layouts.page_header>

      <div id="template-groups" class="space-y-5">
        <section
          :for={{group, index} <- Enum.with_index(@groups, 1)}
          id={"type-#{group.type}"}
          class="reveal rounded-2xl border border-line bg-surface p-5 shadow-card sm:p-6"
          style={"--i: #{index}"}
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <h2 class="text-base font-semibold">{Labels.event_type(group.type)}</h2>
              <span
                :if={group.active}
                class="inline-flex items-center gap-2 rounded-full bg-ok-soft px-3 py-1 text-xs font-medium text-ok"
              >
                <span class="live-dot relative size-1.5 rounded-full bg-ok text-ok"></span> Ativo
              </span>
              <span
                :if={!group.active}
                class="inline-flex items-center gap-2 rounded-full bg-warn-soft px-3 py-1 text-xs font-medium text-warn"
              >
                <span class="size-1.5 rounded-full bg-warn"></span> Sem template
              </span>
            </div>
            <.link
              :if={!group.active}
              id={"create-#{group.type}"}
              navigate={~p"/painel/templates/novo?#{[tipo: group.type]}"}
              class="inline-flex items-center gap-2 rounded-lg bg-brand px-3.5 py-2 text-sm font-semibold text-brand-on shadow-sm transition duration-200 hover:bg-brand-hover active:scale-[0.99]"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Criar template
            </.link>
          </div>

          <div :if={group.active} id={"template-#{group.active.id}"} class="mt-4 space-y-4">
            <.bubble
              caption="Como o cliente lê (com valores de exemplo)"
              text={
                group.preview ||
                  "Não foi possível montar o exemplo: o texto usa uma variável que não existe mais."
              }
              muted={is_nil(group.preview)}
            />

            <div class="flex flex-wrap items-center justify-between gap-3">
              <p class="font-mono text-xs text-ink-2">
                {Labels.delivery(group.active.provider, group.active.channel)}
                <span class="mx-1.5 text-ink-3">·</span>
                {Format.number(group.active.cost)} {if group.active.cost == 1,
                  do: "crédito",
                  else: "créditos"} por mensagem
              </p>
              <div class="flex items-center gap-1">
                <.link
                  id={"edit-#{group.active.id}"}
                  navigate={~p"/painel/templates/#{group.active.id}/editar"}
                  class="rounded-md px-2.5 py-1.5 text-xs font-medium text-ink-2 transition-colors hover:bg-surface-2 hover:text-ink"
                >
                  Editar
                </.link>
                <button
                  id={"deactivate-#{group.active.id}"}
                  type="button"
                  phx-click="deactivate"
                  phx-value-id={group.active.id}
                  data-confirm="Desativar este template? Os próximos eventos desse tipo deixam de gerar mensagem."
                  class="rounded-md px-2.5 py-1.5 text-xs font-medium text-bad transition-colors hover:bg-bad-soft"
                >
                  Desativar
                </button>
              </div>
            </div>
          </div>

          <p :if={!group.active} class="mt-3 text-sm text-ink-2">
            Os eventos desse tipo são recebidos, mas não geram mensagem.
          </p>

          <ul
            :if={group.inactive != []}
            id={"inactive-#{group.type}"}
            class="mt-4 divide-y divide-line rounded-xl border border-dashed border-line"
          >
            <li
              :for={template <- group.inactive}
              id={"template-#{template.id}"}
              class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
            >
              <div class="min-w-0">
                <p class="truncate text-sm text-ink-2">{template.body}</p>
                <p class="mt-0.5 font-mono text-[11px] text-ink-3">
                  Desativado · {Labels.delivery(template.provider, template.channel)}
                </p>
              </div>
              <div class="flex items-center gap-1">
                <.link
                  id={"edit-#{template.id}"}
                  navigate={~p"/painel/templates/#{template.id}/editar"}
                  class="rounded-md px-2.5 py-1.5 text-xs font-medium text-ink-2 transition-colors hover:bg-surface-2 hover:text-ink"
                >
                  Editar
                </.link>
                <button
                  id={"activate-#{template.id}"}
                  type="button"
                  phx-click="activate"
                  phx-value-id={template.id}
                  class="rounded-md px-2.5 py-1.5 text-xs font-medium text-brand transition-colors hover:bg-brand-soft"
                >
                  Ativar
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
