defmodule Notifiq.Test.MensageriaHelpers do
  @moduledoc "Builders and invariants shared by the Mensageria tests (Spec 006)."

  import Ecto.Query

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.CreditTransaction
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo
  alias Notifiq.Tenants

  @doc "Creates a tenant holding `credits` (bought through the ledger, like in production)."
  def tenant!(credits \\ 0, name_prefix \\ "Tenant") do
    {:ok, tenant} =
      Tenants.create_tenant(%{name: "#{name_prefix} #{System.unique_integer([:positive])}"})

    if credits > 0, do: {:ok, _balance} = Mensageria.add_credits(tenant.id, credits, "adjustment")

    tenant
  end

  @doc "Connects `tenant` to `account` of `source`, as the merchant would."
  def integration!(tenant, source, account) do
    {:ok, integration} =
      Tenants.connect_integration(tenant.id, %{source: source, external_account_id: account})

    integration
  end

  @doc """
  Stores an event received for `tenant`, as ingestion would. `payload` is the canonical
  event as it comes back from the database (string keys); the default is a complete one.
  """
  def event!(tenant, external_prefix \\ "evt", payload \\ nil, event_type \\ "order_created") do
    Repo.insert!(%WebhookEvent{
      tenant_id: tenant.id,
      source: "fake",
      external_event_id: "#{external_prefix}-#{System.unique_integer([:positive])}",
      event_type: event_type,
      payload: payload || canonical_payload()
    })
  end

  @doc "A stored canonical event payload; `overrides` are merged over the top level."
  def canonical_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "recipient" => %{"name" => "Maria da Silva", "phone" => "+5511999998888"},
        "context" => %{"numero_pedido" => "1234", "nome_cliente" => "Maria da Silva"}
      },
      overrides
    )
  end

  @doc "An active template for `tenant`; `overrides` replace the defaults."
  def template!(tenant, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          event_type: "order_created",
          channel: "sms",
          provider: "fake_sms",
          body: "Olá {{nome_cliente|cliente}}, seu pedido {{numero_pedido}} foi recebido."
        },
        overrides
      )

    {:ok, template} = Notifiq.Templates.create_template(tenant.id, attrs)
    template
  end

  @doc "Valid `Mensageria.reserve/1` attributes."
  def reservation(tenant, event, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: tenant.id,
        webhook_event_id: event.id,
        provider: "fake_sms",
        channel: :sms,
        recipient: "+5511999998888",
        body: "Seu pedido foi faturado"
      },
      overrides
    )
  end

  @doc "Reserves a dispatch for a fresh event and returns the log."
  def reserve!(tenant, overrides \\ %{}) do
    {:ok, log} = Mensageria.reserve(reservation(tenant, event!(tenant), overrides))
    log
  end

  def balance(tenant), do: Mensageria.credit_balance(tenant.id)

  def ledger_sum(tenant_id) do
    Repo.one(from c in CreditTransaction, where: c.tenant_id == ^tenant_id, select: sum(c.amount)) ||
      0
  end

  def ledger_count(tenant_id) do
    Repo.aggregate(from(c in CreditTransaction, where: c.tenant_id == ^tenant_id), :count)
  end

  @doc "The core invariant (FR-9): balance is never negative and equals the ledger sum."
  def assert_invariant!(tenant_id) do
    balance = Mensageria.credit_balance(tenant_id)
    sum = ledger_sum(tenant_id)

    unless balance >= 0 and balance == sum do
      raise ExUnit.AssertionError,
        message: "invariant broken for #{tenant_id}: balance=#{balance} ledger_sum=#{sum}"
    end

    :ok
  end
end
