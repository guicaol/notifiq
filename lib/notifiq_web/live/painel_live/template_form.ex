defmodule NotifiqWeb.PainelLive.TemplateForm do
  @moduledoc """
  Writes and edits a message template (Spec 011, FR-5 to FR-9), with a preview that updates
  as the merchant types.

  What the browser may decide: the event type (only when creating, and only among the types
  with no active template), how to send (one of the registered provider/channel pairs), the
  text and the cost. The tenant and `active` are never read from the form, and the type
  cannot be changed once the template exists.

  Variables are checked against what the sources declare (`Templates.available_variables/0`):
  a typo such as `{{nome}}` is refused here, where the merchant can fix it, instead of
  failing every event later. The preview uses the sources' example values, never a real
  customer's.
  """

  use NotifiqWeb, :live_view

  import NotifiqWeb.PainelComponents

  alias Notifiq.Accounts.Scope
  alias Notifiq.Channels.Registry, as: ChannelRegistry
  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Templates
  alias Notifiq.Templates.MessageTemplate
  alias NotifiqWeb.Labels

  @max_body 1000

  @impl true
  def mount(params, _session, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)
    deliveries = deliveries()

    case start(socket.assigns.live_action, tenant_id, params, deliveries) do
      {:ok, template, types, initial} ->
        socket =
          socket
          |> assign(:page_title, if(template.id, do: "Editar template", else: "Novo template"))
          |> assign(
            :caption,
            "Painel / Templates / #{if(template.id, do: "Editar", else: "Novo")}"
          )
          |> assign(:template, template)
          |> assign(:types, types)
          |> assign(:deliveries, deliveries)
          |> assign(:variables, Templates.available_variables())
          |> assign(:max_body, @max_body)
          |> assign_form(initial, nil)

        {:ok, socket}

      {:redirect, message} ->
        {:ok, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/painel/templates")}
    end
  end

  defp start(:new, tenant_id, params, deliveries) do
    active_types =
      tenant_id
      |> Templates.list_templates()
      |> Enum.filter(& &1.active)
      |> MapSet.new(& &1.event_type)

    case Enum.reject(EventTypes.all(), &MapSet.member?(active_types, &1)) do
      [] ->
        {:redirect, "Todos os tipos de evento já têm um template ativo."}

      [first | _] = types ->
        chosen = if params["tipo"] in types, do: params["tipo"], else: first

        initial = %{
          "event_type" => chosen,
          "delivery" => deliveries |> List.first(%{}) |> Map.get(:value, ""),
          "body" => "",
          "cost" => "1"
        }

        {:ok, %MessageTemplate{tenant_id: tenant_id}, types, initial}
    end
  end

  defp start(:edit, tenant_id, %{"id" => id}, _deliveries) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %MessageTemplate{} = template <- Templates.get_template(tenant_id, uuid) do
      initial = %{
        "event_type" => template.event_type,
        "delivery" => "#{template.provider}:#{template.channel}",
        "body" => template.body,
        "cost" => Integer.to_string(template.cost)
      }

      {:ok, template, [], initial}
    else
      _unknown -> {:redirect, "Template não encontrado."}
    end
  end

  # Every provider/channel pair that is registered, as one choice each. The form sends the
  # `value`; it is looked up here and never turned into an atom.
  defp deliveries do
    for {provider, module} <- Enum.sort_by(ChannelRegistry.providers(), &elem(&1, 0)),
        channel <- module.supported_channels() do
      channel = Atom.to_string(channel)

      %{
        value: "#{provider}:#{channel}",
        provider: provider,
        channel: channel,
        label: Labels.delivery(provider, channel)
      }
    end
  end

  @impl true
  def handle_event("validate", %{"template" => params}, socket) when is_map(params),
    do: {:noreply, assign_form(socket, texts_only(params), :validate)}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"template" => params}, socket) when is_map(params) do
    params = texts_only(params)
    changeset = changeset(socket, params, :validate)

    if changeset.valid? do
      persist(socket.assigns.live_action, domain_attrs(socket, params), params, socket)
    else
      {:noreply, put_form(socket, changeset, params)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # A form only ever sends text. Anything else is a hand-made request, and a map in a text
  # field would crash the page when it is drawn again: it is treated as empty.
  defp texts_only(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, value}
      {key, _other} -> {key, ""}
    end)
  end

  defp persist(:new, attrs, params, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    case Templates.create_template(tenant_id, attrs) do
      {:ok, _template} -> {:noreply, saved(socket, "Template criado.")}
      {:error, changeset} -> {:noreply, rejected(socket, changeset, params)}
    end
  end

  defp persist(:edit, attrs, params, socket) do
    tenant_id = Scope.tenant_id(socket.assigns.current_scope)

    case Templates.update_template(tenant_id, socket.assigns.template.id, attrs) do
      {:ok, _template} ->
        {:noreply, saved(socket, "Template salvo.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Template não encontrado.")
         |> push_navigate(to: ~p"/painel/templates")}

      {:error, changeset} ->
        {:noreply, rejected(socket, changeset, params)}
    end
  end

  defp saved(socket, message) do
    socket |> put_flash(:info, message) |> push_navigate(to: ~p"/painel/templates")
  end

  # The database said no (for example another template became active meanwhile).
  defp rejected(socket, changeset, params) do
    put_form(socket, changeset |> translate_errors() |> Map.put(:action, :insert), params)
  end

  # --- the form --------------------------------------------------------------------

  defp assign_form(socket, params, action),
    do: put_form(socket, changeset(socket, params, action), params)

  defp put_form(socket, changeset, params) do
    socket
    |> assign(:form, to_form(changeset, as: :template))
    |> assign(:preview, preview(params["body"]))
  end

  defp changeset(socket, params, action) do
    socket.assigns.template
    |> Templates.change_template(form_params(socket, params))
    |> require_cost(params)
    |> add_unknown_variables()
    |> translate_errors()
    |> Map.put(:action, action)
  end

  # What goes to the changeset: the browser's fields minus everything it may not decide,
  # plus the provider and channel resolved from the chosen pair. The `_unused_*` markers
  # stay, so a field the merchant has not touched yet shows no error.
  defp form_params(socket, params) do
    params
    |> Map.drop(["provider", "channel", "tenant_id", "active"])
    |> drop_event_type(socket.assigns.live_action)
    |> Map.merge(delivery_params(socket.assigns.deliveries, params["delivery"]))
  end

  defp drop_event_type(params, :edit), do: Map.delete(params, "event_type")
  defp drop_event_type(params, :new), do: params

  defp delivery_params(deliveries, value) do
    case Enum.find(deliveries, &(&1.value == value)) do
      nil -> %{}
      delivery -> %{"provider" => delivery.provider, "channel" => delivery.channel}
    end
  end

  # Only these reach `Templates`: never the tenant, `active` or (when editing) the type.
  defp domain_attrs(socket, params) do
    Map.take(form_params(socket, params), ["event_type", "provider", "channel", "body", "cost"])
  end

  # An empty number box would quietly fall back to the current cost; the merchant is asked
  # for a number instead.
  defp require_cost(changeset, params) do
    if String.trim(params["cost"] || "") == "" do
      Ecto.Changeset.add_error(changeset, :cost, "can't be blank", validation: :required)
    else
      changeset
    end
  end

  defp add_unknown_variables(changeset) do
    body = Ecto.Changeset.get_field(changeset, :body)

    case is_binary(body) && Templates.unknown_variables(body) do
      {:ok, [_ | _] = names} ->
        Ecto.Changeset.add_error(changeset, :body, "unknown_variables", names: names)

      _fine_or_unparsable ->
        changeset
    end
  end

  # The changeset speaks English and knows `provider` and `channel`; the merchant sees
  # Portuguese and one field, "how to send".
  defp translate_errors(changeset) do
    errors =
      for {field, error} <- changeset.errors do
        {display_field(field), {error_text(field, error), []}}
      end

    %{changeset | errors: Enum.uniq(errors), valid?: errors == []}
  end

  defp display_field(field) when field in [:provider, :channel], do: :delivery
  defp display_field(field), do: field

  defp error_text(_field, {"unknown_variables", opts}) do
    names = opts |> Keyword.get(:names, []) |> Enum.map_join(", ", &token/1)
    "Variável que não existe: #{names}. Use as variáveis listadas abaixo do texto."
  end

  defp error_text(field, {message, opts}) do
    cond do
      opts[:validation] == :required and field in [:provider, :channel] ->
        "Escolha como enviar."

      opts[:validation] == :required ->
        "Preencha este campo."

      opts[:validation] == :length and opts[:kind] == :max ->
        "Use no máximo #{opts[:count]} caracteres."

      opts[:validation] in [:number, :cast] and field == :cost ->
        "Use um número inteiro de 1 a 10."

      opts[:validation] == :inclusion and field == :event_type ->
        "Escolha um tipo de evento da lista."

      opts[:validation] == :inclusion and field == :channel ->
        "Escolha como enviar."

      opts[:constraint] == :unique ->
        "Já existe um template ativo para este tipo de evento. Desative-o antes."

      message == "has an invalid {{variable}}" ->
        "Há uma variável mal escrita. Use o formato #{token("nome")}, só com letras minúsculas, números e _."

      field in [:provider, :channel] ->
        "Escolha como enviar."

      true ->
        "Valor inválido."
    end
  end

  # --- the preview -----------------------------------------------------------------

  defp preview(body) when is_binary(body) do
    if String.trim(body) == "" do
      :empty
    else
      case Templates.preview(body) do
        {:ok, text} ->
          {:ok, text}

        {:error, :invalid_syntax} ->
          {:error, "As chaves estão incorretas. Cada variável é escrita assim: #{token("nome")}."}

        {:error, {:missing_variable, name}} ->
          {:error, "A variável #{token(name)} não existe."}

        {:error, _other} ->
          {:error, "Não foi possível montar o exemplo."}
      end
    end
  end

  defp preview(_body), do: :empty

  defp token(name), do: "{{" <> name <> "}}"

  defp body_length(form) do
    case form[:body].value do
      body when is_binary(body) -> String.length(body)
      _other -> 0
    end
  end

  defp delivery_prompt(form, deliveries) do
    if Enum.any?(deliveries, &(&1.value == form[:delivery].value)), do: nil, else: "Escolha..."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:templates}>
      <.link
        id="back-to-templates"
        navigate={~p"/painel/templates"}
        class="reveal mb-5 inline-flex items-center gap-1.5 text-sm font-medium text-ink-2 transition-colors hover:text-ink"
        style="--i: 0"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Todos os templates
      </.link>

      <Layouts.page_header caption={@caption} title={@page_title}>
        Escreva o texto e veja, ao lado, como ele fica com valores de exemplo.
      </Layouts.page_header>

      <div class="grid gap-6 lg:grid-cols-[1.3fr_1fr]">
        <.form
          for={@form}
          id="template-form"
          phx-change="validate"
          phx-submit="save"
          class="reveal space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-card sm:p-6"
          style="--i: 1"
        >
          <%= if @live_action == :new do %>
            <.input
              field={@form[:event_type]}
              id="template-event-type"
              type="select"
              label="Tipo de evento"
              options={Enum.map(@types, &{Labels.event_type(&1), &1})}
            />
          <% else %>
            <div>
              <p class="label mb-1">Tipo de evento</p>
              <p id="template-event-type-fixed" class="text-sm font-medium">
                {Labels.event_type(@template.event_type)}
              </p>
            </div>
          <% end %>

          <.input
            field={@form[:delivery]}
            id="template-delivery"
            type="select"
            label="Como enviar"
            options={Enum.map(@deliveries, &{&1.label, &1.value})}
            prompt={delivery_prompt(@form, @deliveries)}
          />

          <div>
            <.input
              field={@form[:body]}
              id="template-body"
              type="textarea"
              label="Texto da mensagem"
              rows="6"
              phx-debounce="200"
            />
            <div class="flex items-center justify-between text-xs text-ink-3">
              <span>Variáveis (clique para inserir onde está o cursor)</span>
              <span id="body-count" class="font-mono tabular-nums">
                {body_length(@form)}/{@max_body}
              </span>
            </div>
            <div id="template-variables" class="mt-2 flex flex-wrap gap-2">
              <button
                :for={variable <- @variables}
                id={"variable-#{variable.name}"}
                type="button"
                title={variable.label}
                phx-click={
                  JS.dispatch("phx:insert",
                    detail: %{target: "#template-body", text: token(variable.name)}
                  )
                }
                class="inline-flex items-center gap-1.5 rounded-md bg-brand-soft px-2.5 py-1 font-mono text-xs font-medium text-brand transition hover:brightness-95 active:scale-[0.98]"
              >
                {token(variable.name)}
              </button>
            </div>
          </div>

          <.input
            field={@form[:cost]}
            id="template-cost"
            type="number"
            label="Créditos por mensagem"
            min="1"
            max="10"
          />

          <div class="flex flex-wrap items-center gap-3 pt-2">
            <button
              type="submit"
              id="template-submit"
              phx-disable-with="Salvando..."
              class="group inline-flex items-center gap-2 rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-brand-on shadow-sm transition duration-200 hover:bg-brand-hover active:scale-[0.99]"
            >
              <.icon name="hero-check" class="size-4" />
              {if @live_action == :new, do: "Criar template", else: "Salvar alterações"}
            </button>
            <.link
              id="template-cancel"
              navigate={~p"/painel/templates"}
              class="rounded-lg px-3 py-2.5 text-sm font-medium text-ink-2 transition-colors hover:bg-surface-2 hover:text-ink"
            >
              Cancelar
            </.link>
          </div>
        </.form>

        <div class="space-y-6">
          <section class="reveal space-y-3" style="--i: 2">
            <h2 class="text-sm font-semibold">Pré-visualização</h2>
            <div id="template-preview">
              <%= case @preview do %>
                <% {:ok, text} -> %>
                  <.bubble
                    id="preview-text"
                    caption="Como o cliente lê (valores de exemplo)"
                    text={text}
                  />
                  <p id="preview-count" class="mt-2 text-right font-mono text-xs text-ink-3">
                    {String.length(text)} caracteres
                  </p>
                <% {:error, message} -> %>
                  <div
                    id="preview-warning"
                    class="flex items-start gap-3 rounded-2xl border border-warn/30 bg-warn-soft p-4 text-sm text-warn"
                  >
                    <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
                    <p>{message}</p>
                  </div>
                <% :empty -> %>
                  <div
                    id="preview-empty"
                    class="rounded-2xl border border-dashed border-line p-6 text-center text-sm text-ink-3"
                  >
                    Escreva o texto para ver a pré-visualização.
                  </div>
              <% end %>
            </div>
          </section>

          <section
            class="reveal space-y-2 rounded-2xl border border-line bg-surface-2 p-5 text-sm text-ink-2"
            style="--i: 3"
          >
            <h2 class="text-sm font-semibold text-ink">Como escrever</h2>
            <div phx-no-curly-interpolation class="space-y-2">
              <p>
                Escreva <code class="font-mono text-ink">{{variavel}}</code>
                onde o dado do pedido deve entrar.
              </p>
              <p>
                Para ter um texto de reserva quando o dado faltar, use <code class="font-mono text-ink">{{variavel|texto de reserva}}</code>.
              </p>
            </div>
            <p>Sem texto de reserva, um dado ausente impede o envio daquela mensagem.</p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
