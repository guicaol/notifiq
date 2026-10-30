defmodule Notifiq.Templates do
  @moduledoc """
  A tenant's message templates (Spec 009): what to send for each type of event.

  Every function that reads or writes templates takes the `tenant_id` and filters by it
  (Constitution, principle 7); the tenant is never read from params. The tenant panel
  (Spec 011) calls these; `available_variables/0`, `unknown_variables/1` and `preview/1`
  are the panel's helpers for writing a template and touch no tenant data.
  """

  import Ecto.Query

  alias Notifiq.Integrations.Registry, as: IntegrationsRegistry
  alias Notifiq.Repo
  alias Notifiq.Templates.MessageTemplate
  alias Notifiq.Templates.Renderer

  @doc "Creates an active template for the tenant."
  @spec create_template(Ecto.UUID.t(), map()) ::
          {:ok, MessageTemplate.t()} | {:error, Ecto.Changeset.t()}
  def create_template(tenant_id, attrs) do
    %MessageTemplate{tenant_id: tenant_id}
    |> MessageTemplate.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Edits the tenant's own template."
  @spec update_template(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, MessageTemplate.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_template(tenant_id, id, attrs) do
    with %MessageTemplate{} = template <- get_template(tenant_id, id) do
      template |> MessageTemplate.changeset(attrs) |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Turns the template off; the event type then has no template until another is active."
  @spec deactivate_template(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageTemplate.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def deactivate_template(tenant_id, id), do: set_active(tenant_id, id, false)

  @doc "Turns the template on. Fails if another one is already active for its event type."
  @spec activate_template(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MessageTemplate.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def activate_template(tenant_id, id), do: set_active(tenant_id, id, true)

  defp set_active(tenant_id, id, active) do
    with %MessageTemplate{} = template <- get_template(tenant_id, id) do
      template |> MessageTemplate.active_changeset(active) |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @spec get_template(Ecto.UUID.t(), Ecto.UUID.t()) :: MessageTemplate.t() | nil
  def get_template(tenant_id, id) do
    Repo.one(from t in MessageTemplate, where: t.tenant_id == ^tenant_id and t.id == ^id)
  end

  @spec list_templates(Ecto.UUID.t()) :: [MessageTemplate.t()]
  def list_templates(tenant_id) do
    Repo.all(
      from t in MessageTemplate,
        where: t.tenant_id == ^tenant_id,
        order_by: [asc: t.event_type, desc: t.active, asc: t.inserted_at]
    )
  end

  @doc "The template the tenant sends for `event_type`, if one is active."
  @spec find_active(Ecto.UUID.t(), String.t()) :: MessageTemplate.t() | nil
  def find_active(tenant_id, event_type) do
    Repo.one(
      from t in MessageTemplate,
        where: t.tenant_id == ^tenant_id and t.event_type == ^event_type and t.active
    )
  end

  @doc "A changeset for the template form; the tenant of `template` is never touched."
  @spec change_template(MessageTemplate.t(), map()) :: Ecto.Changeset.t()
  def change_template(%MessageTemplate{} = template, attrs \\ %{}),
    do: MessageTemplate.changeset(template, attrs)

  @core_variable %{name: "recipient_name", label: "Nome do destinatário", example: "Maria Silva"}

  @doc """
  The variables a template can use (Spec 011): the recipient's name, which every event
  carries, followed by what each registered source declares in `metadata/0`. A name that
  two sources declare appears once, the first declaration winning.
  """
  @spec available_variables() :: [%{name: String.t(), label: String.t(), example: String.t()}]
  def available_variables do
    sources = Enum.flat_map(IntegrationsRegistry.describe_all(), & &1.variables)
    Enum.uniq_by([@core_variable | sources], & &1.name)
  end

  @doc """
  The variables `body` uses that no source or event carries, so the template could never be
  rendered (or would silently use its default). `{:error, :invalid_syntax}` when `body` does
  not parse.
  """
  @spec unknown_variables(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_syntax}
  def unknown_variables(body) do
    known = MapSet.new(available_variables(), & &1.name)

    with {:ok, used} <- Renderer.variables(body) do
      {:ok, Enum.reject(used, &MapSet.member?(known, &1))}
    end
  end

  @doc """
  Renders `body` with the example values of `available_variables/0`: what the merchant sees
  before saving. No real event is involved.
  """
  @spec preview(String.t()) :: {:ok, String.t()} | {:error, Renderer.error()}
  def preview(body) do
    Renderer.render(body, Map.new(available_variables(), &{&1.name, &1.example}))
  end

  @doc """
  Renders `template` for a stored event payload (the canonical event as a map): the
  variables are the event's `context` plus `recipient_name`.
  """
  @spec render(MessageTemplate.t(), map()) ::
          {:ok, String.t()} | {:error, Renderer.error()}
  def render(%MessageTemplate{body: body}, %{} = event_payload) do
    Renderer.render(body, variables(event_payload))
  end

  @doc "The values a template can use for an event payload."
  @spec variables(map()) :: map()
  def variables(%{} = event_payload) do
    context = if is_map(event_payload["context"]), do: event_payload["context"], else: %{}
    name = get_in(event_payload, ["recipient", "name"])

    Map.put(context, "recipient_name", name)
  end
end
