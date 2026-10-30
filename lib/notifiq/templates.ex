defmodule Notifiq.Templates do
  @moduledoc """
  A tenant's message templates (Spec 009): what to send for each type of event.

  Every function takes the `tenant_id` and filters by it (Constitution, principle 7); the
  tenant is never read from params. There is no screen for this yet — these are the
  functions the tenant panel will call.
  """

  import Ecto.Query

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
