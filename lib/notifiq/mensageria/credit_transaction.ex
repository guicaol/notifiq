defmodule Notifiq.Mensageria.CreditTransaction do
  @moduledoc """
  A ledger entry: every change to a tenant's `credit_balance` has exactly one (Spec 006).

  `amount` is negative for a debit and positive for a credit. The balance always equals
  the sum of the tenant's entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @reasons ~w(dispatch refund purchase adjustment)

  schema "credit_transactions" do
    field :tenant_id, :binary_id
    field :message_log_id, :binary_id
    field :amount, :integer
    field :reason, :string
    # Assigned by the database; the only order of the ledger that can't tie.
    field :seq, :integer, read_after_writes: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Reasons a ledger entry can have."
  def reasons, do: @reasons

  @doc false
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :message_log_id, :amount, :reason])
    |> validate_required([:tenant_id, :amount, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint(:message_log_id,
      name: :credit_transactions_message_log_id_reason_index,
      message: "already has an entry for this reason"
    )
  end
end
