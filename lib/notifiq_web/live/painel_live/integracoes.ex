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
      <div class="space-y-8">
        <header>
          <h1 class="text-2xl font-semibold tracking-tight">Integrações</h1>
          <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Conecte a conta da sua loja para que os pedidos disparem mensagens.
          </p>
        </header>

        <section class="space-y-3" aria-labelledby="connected-title">
          <h2
            id="connected-title"
            class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400"
          >
            Contas conectadas
          </h2>

          <ul
            id="integrations"
            phx-update="stream"
            class="divide-y divide-zinc-200 overflow-hidden rounded-xl border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-900"
          >
            <li
              id="integrations-empty"
              class="hidden px-4 py-10 text-center text-sm text-zinc-500 only:block dark:text-zinc-400"
            >
              Nenhuma conta conectada ainda.
            </li>
            <li
              :for={{id, integration} <- @streams.integrations}
              id={id}
              class="flex items-center justify-between gap-4 px-4 py-3"
            >
              <div class="min-w-0">
                <p class="text-sm font-medium">
                  {Map.get(@source_names, integration.source, integration.source)}
                </p>
                <p class="truncate font-mono text-xs text-zinc-500 dark:text-zinc-400">
                  {integration.external_account_id}
                </p>
              </div>

              <div class="flex shrink-0 items-center gap-3">
                <span class={[
                  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
                  if(integration.status == "active",
                    do:
                      "bg-emerald-100 text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-300",
                    else: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                  )
                ]}>
                  {if integration.status == "active", do: "Ativa", else: "Desconectada"}
                </span>
                <button
                  :if={integration.status == "active"}
                  id={"disconnect-#{integration.id}"}
                  type="button"
                  phx-click="disconnect"
                  phx-value-id={integration.id}
                  data-confirm="Desconectar esta conta? Os pedidos dela deixam de gerar mensagens."
                  class="rounded-lg px-2.5 py-1.5 text-xs font-medium text-red-700 transition-colors hover:bg-red-50 dark:text-red-300 dark:hover:bg-red-500/10"
                >
                  Desconectar
                </button>
              </div>
            </li>
          </ul>
        </section>

        <section class="space-y-3" aria-labelledby="connect-title">
          <h2
            id="connect-title"
            class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400"
          >
            Conectar uma conta
          </h2>

          <div
            :if={@sources == []}
            id="no-sources"
            class="rounded-xl border border-zinc-200 bg-white px-4 py-6 text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"
          >
            Nenhuma fonte está disponível no momento.
          </div>

          <div
            :if={@sources != []}
            class="rounded-xl border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900"
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
                class="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-emerald-500 active:scale-[0.99] phx-submit-loading:opacity-70"
              >
                <.icon name="hero-link" class="size-4" /> Conectar
              </button>
            </.form>
          </div>
        </section>

        <section :if={@sources != []} id="webhook-urls" class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
            Endereço dos webhooks
          </h2>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            Cadastre este endereço nas configurações de webhook da fonte.
          </p>
          <div
            :for={source <- @sources}
            id={"webhook-url-#{source.key}"}
            class="rounded-xl border border-zinc-200 bg-white px-4 py-3 dark:border-zinc-800 dark:bg-zinc-900"
          >
            <p class="text-xs font-medium text-zinc-500 dark:text-zinc-400">{source.name}</p>
            <code class="mt-1 block break-all text-sm">{url(~p"/api/webhooks/#{source.key}")}</code>
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
