defmodule Notifiq.Templates.MessageTemplate do
  @moduledoc """
  What a tenant sends when a given type of event arrives (Spec 009): the text, the channel
  and the provider. At most one is active per `(tenant, event_type)`.

  The provider is only a registered key (a string): the core never names a specific one
  (Constitution, principle 2). `tenant_id` and `active` are never cast from params.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.Registry
  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Templates.Renderer

  @primary_key {:id, :binary_id, autogenerate: true}

  @max_body_length 1000
  @max_cost 10

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          tenant_id: Ecto.UUID.t(),
          event_type: String.t(),
          channel: String.t(),
          provider: String.t(),
          body: String.t(),
          cost: pos_integer(),
          active: boolean()
        }

  schema "message_templates" do
    field :tenant_id, :binary_id
    field :event_type, :string
    field :channel, :string
    field :provider, :string
    field :body, :string
    field :cost, :integer, default: 1
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:event_type, :channel, :provider, :body, :cost]

  @doc "Changeset for creating or editing a template. See the moduledoc for what is cast."
  def changeset(%__MODULE__{} = template, attrs) do
    template
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:event_type, EventTypes.all())
    |> validate_inclusion(:channel, channels())
    |> validate_length(:body, min: 1, max: @max_body_length)
    |> validate_number(:cost, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_cost)
    |> validate_body_syntax()
    |> validate_provider()
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint(:event_type,
      name: :message_templates_active_event_type_index,
      message: "already has an active template"
    )
  end

  @doc "Changeset that switches a template on or off."
  def active_changeset(%__MODULE__{} = template, active) when is_boolean(active) do
    template
    |> change(active: active)
    |> unique_constraint(:event_type,
      name: :message_templates_active_event_type_index,
      message: "already has an active template"
    )
  end

  @doc "Channel names a template can use, as strings."
  def channels, do: Enum.map(OutboundMessage.channels(), &Atom.to_string/1)

  defp validate_body_syntax(changeset) do
    validate_change(changeset, :body, fn :body, body ->
      case Renderer.parse(body) do
        {:ok, _segments} -> []
        {:error, :invalid_syntax} -> [body: "has an invalid {{variable}}"]
      end
    end)
  end

  # The provider must be registered and must be able to carry the template's channel.
  defp validate_provider(changeset) do
    provider = get_field(changeset, :provider)
    channel = get_field(changeset, :channel)

    cond do
      is_nil(provider) or is_nil(channel) or channel not in channels() ->
        changeset

      true ->
        case Registry.fetch(provider) do
          :error ->
            add_error(changeset, :provider, "is not a registered provider")

          {:ok, module} ->
            supported = Enum.map(module.supported_channels(), &Atom.to_string/1)

            if channel in supported,
              do: changeset,
              else: add_error(changeset, :channel, "is not supported by this provider")
        end
    end
  end
end
