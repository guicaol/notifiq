defmodule Notifiq.Mensageria.CanonicalEvent do
  @moduledoc """
  Formato interno único (versão 1) para o qual todo adapter de integração traduz
  os eventos da sua fonte. Contrato em
  `specs/002-camada-integracoes/contracts/canonical_event.schema.json`.

  Mudança de formato exige incrementar `schema_version`, nunca alterar um campo
  existente silenciosamente.
  """

  @schema_version 1

  @enforce_keys [:source, :external_event_id, :event_type, :recipient]
  defstruct schema_version: @schema_version,
            source: nil,
            external_event_id: nil,
            event_type: nil,
            tenant_id: nil,
            recipient: nil,
            context: %{},
            raw: %{}

  @type recipient :: %{name: String.t() | nil, phone: String.t()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          source: String.t(),
          external_event_id: String.t(),
          event_type: String.t(),
          tenant_id: Ecto.UUID.t() | nil,
          recipient: recipient(),
          context: map(),
          raw: map()
        }

  @doc "Versão atual do formato canônico."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Serializa o evento para um mapa simples, pronto para persistir como JSON."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event), do: Map.from_struct(event)
end
