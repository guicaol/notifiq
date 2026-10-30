defmodule NotifiqWeb.PainelLive.Integracoes do
  @moduledoc """
  Where the merchant connects and disconnects the account of a source (Spec 010,
  FR-16/17). Source names and account labels come from each adapter's `metadata/0`, so
  this page never names a particular source.

  The tenant is always `current_scope`'s. The only identifier the browser sends is the id
  of an integration to disconnect, and `Tenants.disconnect_integration/2` filters it by
  the tenant.
  """

  use NotifiqWeb, :live_view

  alias Notifiq.Accounts.Scope
  alias Notifiq.Integrations.Registry
  alias Notifiq.Tenants

  # What the changeset messages say, in the words the merchant should read. The "already
  # connected" text is the same whoever holds the account (Spec 010, FR-17).
  @error_texts %{
    "is already connected" => "Esta conta já está conectada.",
    "can't be blank" => "Informe o identificador da conta.",
    "is not a registered source" => "Escolha uma das fontes disponíveis."
  }

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)
    sources = Registry.describe_all()

    socket =
      socket
      |> assign(:page_title, "Integrações")
      |> assign(:sources, sources)
      |> assign(:source_names, Map.new(sources, &{&1.key, &1.name}))
      |> assign(:form, blank_form(sources))
      |> assign(:form_version, 0)
      |> stream(:integrations, Tenants.list_integrations(tenant_id))

    {:ok, socket}
  end

  @impl true
  def handle_event("connect", %{"integration" => params}, socket) when is_map(params) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)
    attrs = Map.take(params, ["source", "external_account_id"])

    case Tenants.connect_integration(tenant_id, attrs) do
      {:ok, integration} ->
        {:noreply,
         socket
         |> stream_insert(:integrations, integration, at: 0)
         |> assign(:form, blank_form(socket.assigns.sources))
         |> update(:form_version, &(&1 + 1))
         |> put_flash(:info, "Conta conectada.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, error_form(attrs, changeset))}
    end
  end

  def handle_event("connect", _params, socket), do: {:noreply, socket}

  def handle_event("disconnect", %{"id" => id}, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    # A malformed id would raise in the query; treat it like any other unknown one.
    result =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> Tenants.disconnect_integration(tenant_id, uuid)
        :error -> {:error, :not_found}
      end

    case result do
      {:ok, integration} ->
        {:noreply,
         socket
         |> stream_insert(:integrations, integration)
         |> put_flash(:info, "Conta desconectada.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Integração não encontrada.")}
    end
  end

  defp blank_form(sources) do
    source = sources |> List.first(%{}) |> Map.get(:key, "")
    to_form(%{"source" => source, "external_account_id" => ""}, as: :integration)
  end

  defp error_form(attrs, changeset) do
    errors =
      for {field, {message, _opts}} <- changeset.errors do
        {field, {Map.get(@error_texts, message, "Valor inválido."), []}}
      end

    to_form(
      %{
        "source" => attrs["source"] || "",
        "external_account_id" => String.slice(to_string(attrs["external_account_id"]), 0, 255)
      },
      as: :integration,
      errors: errors
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:integracoes}>
      <Layouts.page_header caption="Painel / Integrações" title="Integrações">
        Conecte a conta da sua loja para que os pedidos disparem mensagens.
      </Layouts.page_header>

      <div class="space-y-10">
        <section class="reveal space-y-3" style="--i: 1" aria-labelledby="connected-title">
          <h2 id="connected-title" class="text-sm font-semibold">Contas conectadas</h2>

          <ul
            id="integrations"
            phx-update="stream"
            class="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-surface shadow-card"
          >
            <li
              id="integrations-empty"
              class="hidden flex-col items-center px-6 py-14 text-center only:flex"
            >
              <span class="flex size-11 items-center justify-center rounded-xl bg-surface-2 ring-1 ring-line">
                <.icon name="hero-puzzle-piece" class="size-5 text-ink-3" />
              </span>
              <p class="mt-4 text-sm font-semibold">Nenhuma conta conectada ainda</p>
              <p class="mt-1 max-w-xs text-sm text-ink-2">
                Conecte uma conta abaixo e cadastre o endereço do webhook na fonte.
              </p>
            </li>
            <li
              :for={{id, integration} <- @streams.integrations}
              id={id}
              class="flex items-center justify-between gap-4 px-5 py-4 transition-colors hover:bg-surface-2"
            >
              <div class="flex min-w-0 items-center gap-4">
                <span class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-chrome font-mono text-base font-semibold uppercase text-volt">
                  {String.first(Map.get(@source_names, integration.source, integration.source))}
                </span>
                <div class="min-w-0">
                  <p class="text-sm font-semibold">
                    {Map.get(@source_names, integration.source, integration.source)}
                  </p>
                  <p class="truncate font-mono text-xs text-ink-2">
                    {integration.external_account_id}
                  </p>
                </div>
              </div>

              <div class="flex shrink-0 items-center gap-3">
                <span
                  :if={integration.status == "active"}
                  class="inline-flex items-center gap-2 rounded-full bg-ok-soft px-3 py-1 text-xs font-medium text-ok"
                >
                  <span class="live-dot relative size-1.5 rounded-full bg-ok text-ok"></span> Ativa
                </span>
                <span
                  :if={integration.status != "active"}
                  class="inline-flex items-center gap-2 rounded-full bg-surface-2 px-3 py-1 text-xs font-medium text-ink-2 ring-1 ring-line"
                >
                  <span class="size-1.5 rounded-full bg-ink-3"></span> Desconectada
                </span>
                <button
                  :if={integration.status == "active"}
                  id={"disconnect-#{integration.id}"}
                  type="button"
                  phx-click="disconnect"
                  phx-value-id={integration.id}
                  data-confirm="Desconectar esta conta? Os pedidos dela deixam de gerar mensagens."
                  class="rounded-md px-2.5 py-1.5 text-xs font-medium text-bad transition-colors hover:bg-bad-soft"
                >
                  Desconectar
                </button>
              </div>
            </li>
          </ul>
        </section>

        <section class="reveal grid gap-6 lg:grid-cols-[1fr_1.4fr]" style="--i: 2">
          <div>
            <h2 id="connect-title" class="text-sm font-semibold">Conectar uma conta</h2>
            <ol class="mt-4 space-y-4 text-sm text-ink-2">
              <li class="flex gap-3">
                <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-brand-soft font-mono text-xs font-semibold text-brand">
                  1
                </span>
                <span>Informe o identificador da sua conta na fonte.</span>
              </li>
              <li class="flex gap-3">
                <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-brand-soft font-mono text-xs font-semibold text-brand">
                  2
                </span>
                <span>Cadastre o endereço do webhook, mostrado mais abaixo, nas configurações da fonte.</span>
              </li>
              <li class="flex gap-3">
                <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-brand-soft font-mono text-xs font-semibold text-brand">
                  3
                </span>
                <span>Cada pedido novo passa a gerar uma mensagem, se houver template ativo.</span>
              </li>
            </ol>
          </div>

          <div
            :if={@sources == []}
            id="no-sources"
            class="rounded-2xl border border-dashed border-line bg-surface px-6 py-10 text-center text-sm text-ink-2"
          >
            Nenhuma fonte está disponível no momento.
          </div>

          <div
            :if={@sources != []}
            class="rounded-2xl border border-line bg-surface p-6 shadow-card"
          >
            <.form for={@form} id="integration-form" phx-submit="connect" class="space-y-4">
              <.input
                :if={length(@sources) > 1}
                field={@form[:source]}
                id="integration-source"
                type="select"
                label="Fonte"
                options={Enum.map(@sources, &{&1.name, &1.key})}
              />
              <.input
                :if={length(@sources) == 1}
                field={@form[:source]}
                id="integration-source"
                type="hidden"
              />
              <%!-- A new wrapper id after a success remounts the field, emptying it even while focused. --%>
              <div id={"account-field-#{@form_version}"}>
                <.input
                  field={@form[:external_account_id]}
                  id="integration-account"
                  type="text"
                  label={account_label(@sources, @form[:source].value)}
                  autocomplete="off"
                  spellcheck="false"
                />
              </div>

              <button
                type="submit"
                id="integration-submit"
                class="group inline-flex items-center gap-2 rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-brand-on shadow-sm transition duration-200 hover:bg-brand-hover active:scale-[0.99] phx-submit-loading:opacity-70"
              >
                <.icon name="hero-link" class="size-4" /> Conectar conta
              </button>
            </.form>
          </div>
        </section>

        <section :if={@sources != []} id="webhook-urls" class="reveal space-y-3" style="--i: 3">
          <div>
            <h2 class="text-sm font-semibold">Endereço dos webhooks</h2>
            <p class="mt-1 text-sm text-ink-2">
              Cadastre este endereço nas configurações de webhook da fonte.
            </p>
          </div>

          <div
            :for={source <- @sources}
            id={"webhook-url-#{source.key}"}
            class="flex flex-col gap-3 rounded-2xl bg-hero p-5 text-hero-text shadow-card sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0">
              <p class="font-mono text-[10px] font-medium uppercase tracking-[0.2em] text-white/50">
                {source.name} · POST
              </p>
              <code class="mt-1.5 block break-all font-mono text-[13px] text-volt">
                {url(~p"/api/webhooks/#{source.key}")}
              </code>
            </div>
            <button
              type="button"
              id={"copy-#{source.key}"}
              data-copy
              data-text={url(~p"/api/webhooks/#{source.key}")}
              phx-click={JS.dispatch("phx:copy")}
              class="inline-flex shrink-0 items-center justify-center gap-2 rounded-lg bg-white/10 px-3.5 py-2 text-xs font-semibold text-white ring-1 ring-white/15 transition hover:bg-white/15 active:scale-[0.98]"
            >
              <span class="when-idle inline-flex items-center gap-2">
                <.icon name="hero-clipboard-document" class="size-4" /> Copiar
              </span>
              <span class="when-copied hidden items-center gap-2 text-volt">
                <.icon name="hero-check" class="size-4" /> Copiado
              </span>
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp account_label(sources, key) do
    case Enum.find(sources, &(&1.key == key)) do
      %{account_label: label} -> label
      nil -> "Identificador da conta"
    end
  end
end
