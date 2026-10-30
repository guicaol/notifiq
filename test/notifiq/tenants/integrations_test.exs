defmodule Notifiq.Tenants.IntegrationsTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Tenants
  alias Notifiq.Tenants.Integration

  describe "connect_integration/2 (AC-1, AC-2)" do
    test "connects the tenant to an account of a registered source" do
      tenant = tenant!()

      assert {:ok, %Integration{} = integration} =
               Tenants.connect_integration(tenant.id, %{
                 source: "fake",
                 external_account_id: "acme"
               })

      assert integration.tenant_id == tenant.id
      assert integration.source == "fake"
      assert integration.external_account_id == "acme"
      assert integration.status == "active"
    end

    test "trims the account id" do
      tenant = tenant!()

      assert {:ok, %Integration{external_account_id: "acme"}} =
               Tenants.connect_integration(tenant.id, %{
                 source: "fake",
                 external_account_id: "  acme "
               })
    end

    test "an active account can't be connected twice, not even by another tenant" do
      a = tenant!()
      b = tenant!()
      attrs = %{source: "fake", external_account_id: "shared"}

      assert {:ok, _integration} = Tenants.connect_integration(a.id, attrs)

      assert {:error, own} = Tenants.connect_integration(a.id, attrs)
      assert %{external_account_id: ["is already connected"]} = errors_on(own)

      assert {:error, other} = Tenants.connect_integration(b.id, attrs)
      assert %{external_account_id: ["is already connected"]} = errors_on(other)

      assert Tenants.list_integrations(b.id) == []
    end

    test "the same account id under another source is a different account" do
      tenant = tenant!()

      assert {:ok, _} =
               Tenants.connect_integration(tenant.id, %{source: "fake", external_account_id: "42"})

      assert {:ok, _} =
               Tenants.connect_integration(tenant.id, %{
                 source: "other_fake",
                 external_account_id: "42"
               })
    end

    test "an account freed by a disconnection can be connected by another tenant" do
      a = tenant!()
      b = tenant!()
      attrs = %{source: "fake", external_account_id: "moving"}

      {:ok, first} = Tenants.connect_integration(a.id, attrs)

      assert {:ok, %Integration{status: "disabled"}} =
               Tenants.disconnect_integration(a.id, first.id)

      assert {:ok, %Integration{status: "active"}} = Tenants.connect_integration(b.id, attrs)
      assert {:ok, tenant_id} = Tenants.resolve_tenant("fake", "moving")
      assert tenant_id == b.id
    end

    test "refuses a source that isn't registered" do
      tenant = tenant!()

      assert {:error, changeset} =
               Tenants.connect_integration(tenant.id, %{
                 source: "nope",
                 external_account_id: "acme"
               })

      assert %{source: ["is not a registered source"]} = errors_on(changeset)
    end

    test "refuses missing, blank and oversized accounts" do
      tenant = tenant!()

      for attrs <- [
            %{source: "fake"},
            %{source: "fake", external_account_id: ""},
            %{source: "fake", external_account_id: "   "},
            %{source: "fake", external_account_id: String.duplicate("a", 256)},
            %{external_account_id: "acme"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Tenants.connect_integration(tenant.id, attrs)
      end

      assert Tenants.list_integrations(tenant.id) == []
    end

    test "refuses a tenant that doesn't exist" do
      assert {:error, changeset} =
               Tenants.connect_integration(Ecto.UUID.generate(), %{
                 source: "fake",
                 external_account_id: "acme"
               })

      assert %{tenant_id: ["does not exist"]} = errors_on(changeset)
    end

    test "the tenant comes from the caller, never from the params" do
      owner = tenant!()
      victim = tenant!()

      assert {:ok, integration} =
               Tenants.connect_integration(owner.id, %{
                 "source" => "fake",
                 "external_account_id" => "acme",
                 "tenant_id" => victim.id,
                 "status" => "disabled"
               })

      assert integration.tenant_id == owner.id
      assert integration.status == "active"
      assert Tenants.list_integrations(victim.id) == []
    end

    test "the database allows only the two known statuses" do
      tenant = tenant!()

      {:ok, integration} =
        Tenants.connect_integration(tenant.id, %{source: "fake", external_account_id: "acme"})

      assert_raise Postgrex.Error, ~r/status_known/, fn ->
        Repo.query!("UPDATE integrations SET status = 'paused' WHERE id = $1", [
          Ecto.UUID.dump!(integration.id)
        ])
      end
    end
  end

  describe "resolve_tenant/2" do
    test "finds the tenant that owns an active account" do
      tenant = tenant!()
      integration!(tenant, "fake", "acme")

      assert {:ok, tenant_id} = Tenants.resolve_tenant("fake", "acme")
      assert tenant_id == tenant.id
    end

    test "knows nothing about unconnected, disabled or differently written accounts" do
      tenant = tenant!()
      integration = integration!(tenant, "fake", "acme")

      assert :error = Tenants.resolve_tenant("fake", "other")
      assert :error = Tenants.resolve_tenant("other_fake", "acme")
      assert :error = Tenants.resolve_tenant("fake", "ACME")

      {:ok, _} = Tenants.disconnect_integration(tenant.id, integration.id)
      assert :error = Tenants.resolve_tenant("fake", "acme")
    end

    test "ignores anything that isn't a pair of strings" do
      assert :error = Tenants.resolve_tenant(nil, "acme")
      assert :error = Tenants.resolve_tenant("fake", nil)
      assert :error = Tenants.resolve_tenant("fake", 42)
    end
  end

  describe "isolation (AC-10)" do
    setup do
      a = tenant!(0, "A")
      b = tenant!(0, "B")
      %{a: a, b: b, integration_a: integration!(a, "fake", "account-a")}
    end

    test "a tenant lists and fetches only its own integrations", %{
      a: a,
      b: b,
      integration_a: integration_a
    } do
      integration_b = integration!(b, "fake", "account-b")

      assert [%Integration{id: id}] = Tenants.list_integrations(a.id)
      assert id == integration_a.id
      assert [%Integration{id: id_b}] = Tenants.list_integrations(b.id)
      assert id_b == integration_b.id

      assert Tenants.get_integration(a.id, integration_a.id)
      assert Tenants.get_integration(b.id, integration_a.id) == nil
    end

    test "a tenant can't disconnect another tenant's integration", %{
      a: a,
      b: b,
      integration_a: integration_a
    } do
      assert {:error, :not_found} = Tenants.disconnect_integration(b.id, integration_a.id)

      assert %Integration{status: "active"} = Tenants.get_integration(a.id, integration_a.id)
      assert {:ok, tenant_id} = Tenants.resolve_tenant("fake", "account-a")
      assert tenant_id == a.id
    end

    test "disconnecting a missing integration is :not_found", %{a: a} do
      assert {:error, :not_found} = Tenants.disconnect_integration(a.id, Ecto.UUID.generate())
    end
  end
end
