defmodule Notifiq.TemplatesTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Templates
  alias Notifiq.Templates.MessageTemplate

  @valid %{
    event_type: "order_invoiced",
    channel: "sms",
    provider: "fake_sms",
    body: "Olá {{nome_cliente|cliente}}, pedido {{numero_pedido}} faturado."
  }

  describe "create_template/2 (AC-1)" do
    test "creates an active template owned by the caller's tenant" do
      tenant = tenant!()

      assert {:ok, %MessageTemplate{} = template} = Templates.create_template(tenant.id, @valid)

      assert template.tenant_id == tenant.id
      assert template.active
      assert template.cost == 1
      assert template.event_type == "order_invoiced"
      assert template.provider == "fake_sms"
    end

    test "accepts a provider that carries several channels, and a cost" do
      tenant = tenant!()
      attrs = Map.merge(@valid, %{provider: "fake_multi", channel: "whatsapp", cost: 3})

      assert {:ok, %MessageTemplate{channel: "whatsapp", cost: 3}} =
               Templates.create_template(tenant.id, attrs)
    end

    test "the tenant and the active flag come from the caller, never from the params" do
      owner = tenant!()
      victim = tenant!()

      assert {:ok, template} =
               Templates.create_template(
                 owner.id,
                 Map.merge(@valid, %{tenant_id: victim.id, active: false})
               )

      assert template.tenant_id == owner.id
      assert template.active
      assert Templates.list_templates(victim.id) == []
    end
  end

  describe "validation (AC-2)" do
    setup do
      %{tenant: tenant!()}
    end

    defp create(tenant, overrides),
      do: Templates.create_template(tenant.id, Map.merge(@valid, overrides))

    test "requires every field", %{tenant: tenant} do
      assert {:error, changeset} = Templates.create_template(tenant.id, %{})

      assert Map.keys(errors_on(changeset)) |> Enum.sort() ==
               [:body, :channel, :event_type, :provider]
    end

    test "refuses an event type nobody emits", %{tenant: tenant} do
      assert {:error, changeset} = create(tenant, %{event_type: "order_teleported"})
      assert %{event_type: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses an unknown channel", %{tenant: tenant} do
      assert {:error, changeset} = create(tenant, %{channel: "pigeon"})
      assert %{channel: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses a provider that isn't registered", %{tenant: tenant} do
      assert {:error, changeset} = create(tenant, %{provider: "nope"})
      assert %{provider: ["is not a registered provider"]} = errors_on(changeset)
    end

    test "refuses a channel the provider can't carry", %{tenant: tenant} do
      assert {:error, changeset} = create(tenant, %{provider: "fake_sms", channel: "whatsapp"})
      assert %{channel: ["is not supported by this provider"]} = errors_on(changeset)
    end

    test "refuses an empty or oversized body", %{tenant: tenant} do
      assert {:error, empty} = create(tenant, %{body: ""})
      assert %{body: ["can't be blank"]} = errors_on(empty)

      assert {:error, long} = create(tenant, %{body: String.duplicate("a", 1001)})
      assert %{body: ["should be at most 1000 character(s)"]} = errors_on(long)

      assert {:ok, _template} = create(tenant, %{body: String.duplicate("a", 1000)})
    end

    test "refuses a body with a malformed variable", %{tenant: tenant} do
      for body <- ["Olá {{nome", "Olá nome}}", "Olá {{}}", "Olá {{1x}}", "{{a|{{b}}}}"] do
        assert {:error, changeset} = create(tenant, %{body: body}), inspect(body)
        assert %{body: ["has an invalid {{variable}}"]} = errors_on(changeset)
      end
    end

    test "refuses a cost outside 1 to 10", %{tenant: tenant} do
      for cost <- [0, -1, 11, 100] do
        assert {:error, changeset} = create(tenant, %{cost: cost}), inspect(cost)
        assert %{cost: [_message]} = errors_on(changeset)
      end

      assert {:ok, _} = create(tenant, %{cost: 10})
    end

    test "refuses a second active template for the same event type", %{tenant: tenant} do
      assert {:ok, _first} = create(tenant, %{})
      assert {:error, changeset} = create(tenant, %{body: "Outro texto"})

      assert %{event_type: ["already has an active template"]} = errors_on(changeset)
    end

    test "different event types and different tenants don't clash", %{tenant: tenant} do
      other = tenant!()

      assert {:ok, _} = create(tenant, %{})
      assert {:ok, _} = create(tenant, %{event_type: "order_shipped"})
      assert {:ok, _} = create(other, %{})
    end

    test "the database enforces the cost range too", %{tenant: tenant} do
      template = template!(tenant)

      assert_raise Postgrex.Error, ~r/cost_between_1_and_10/, fn ->
        Repo.query!("UPDATE message_templates SET cost = 99 WHERE id = $1", [
          Ecto.UUID.dump!(template.id)
        ])
      end
    end
  end

  describe "editing and switching on and off (AC-4)" do
    setup do
      tenant = tenant!()
      %{tenant: tenant, template: template!(tenant)}
    end

    test "update_template/3 changes the text and re-validates", %{
      tenant: tenant,
      template: template
    } do
      assert {:ok, %MessageTemplate{body: "Novo texto"}} =
               Templates.update_template(tenant.id, template.id, %{body: "Novo texto"})

      assert {:error, changeset} =
               Templates.update_template(tenant.id, template.id, %{body: "{{"})

      assert %{body: ["has an invalid {{variable}}"]} = errors_on(changeset)

      assert Templates.get_template(tenant.id, template.id).body == "Novo texto"
    end

    test "update can't move a template to another tenant or switch it off", %{
      tenant: tenant,
      template: template
    } do
      other = tenant!()

      assert {:ok, updated} =
               Templates.update_template(tenant.id, template.id, %{
                 tenant_id: other.id,
                 active: false
               })

      assert updated.tenant_id == tenant.id
      assert updated.active
    end

    test "deactivating removes it from the search and frees the slot", %{
      tenant: tenant,
      template: template
    } do
      assert %MessageTemplate{} = Templates.find_active(tenant.id, "order_created")

      assert {:ok, %MessageTemplate{active: false}} =
               Templates.deactivate_template(tenant.id, template.id)

      assert Templates.find_active(tenant.id, "order_created") == nil

      assert {:ok, replacement} =
               Templates.create_template(tenant.id, %{@valid | event_type: "order_created"})

      assert Templates.find_active(tenant.id, "order_created").id == replacement.id
    end

    test "reactivating fails while another one is active", %{tenant: tenant, template: template} do
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)

      {:ok, _replacement} =
        Templates.create_template(tenant.id, %{@valid | event_type: "order_created"})

      assert {:error, changeset} = Templates.activate_template(tenant.id, template.id)
      assert %{event_type: ["already has an active template"]} = errors_on(changeset)
    end

    test "reactivating works when the slot is free", %{tenant: tenant, template: template} do
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)

      assert {:ok, %MessageTemplate{active: true}} =
               Templates.activate_template(tenant.id, template.id)

      assert Templates.find_active(tenant.id, "order_created").id == template.id
    end

    test "missing templates are :not_found", %{tenant: tenant} do
      missing = Ecto.UUID.generate()

      assert {:error, :not_found} = Templates.update_template(tenant.id, missing, %{body: "x"})
      assert {:error, :not_found} = Templates.deactivate_template(tenant.id, missing)
      assert {:error, :not_found} = Templates.activate_template(tenant.id, missing)
    end

    test "list_templates/1 shows the tenant's templates, active ones first per type", %{
      tenant: tenant,
      template: template
    } do
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)
      active = template!(tenant)
      shipped = template!(tenant, %{event_type: "order_shipped"})

      assert [first, second, third] = Templates.list_templates(tenant.id)
      assert [first.id, second.id, third.id] == [active.id, template.id, shipped.id]
    end
  end

  describe "isolation (AC-10)" do
    setup do
      a = tenant!(0, "A")
      b = tenant!(0, "B")
      %{a: a, b: b, template_a: template!(a)}
    end

    test "a tenant reads only its own templates", %{a: a, b: b, template_a: template_a} do
      template_b = template!(b)

      assert [%{id: id}] = Templates.list_templates(a.id)
      assert id == template_a.id
      assert [%{id: id_b}] = Templates.list_templates(b.id)
      assert id_b == template_b.id

      assert Templates.get_template(a.id, template_a.id)
      assert Templates.get_template(b.id, template_a.id) == nil
    end

    test "find_active/2 never returns another tenant's template", %{
      a: a,
      b: b,
      template_a: template_a
    } do
      assert Templates.find_active(a.id, "order_created").id == template_a.id
      assert Templates.find_active(b.id, "order_created") == nil
    end

    test "a tenant can't edit, switch off or switch on another tenant's template", %{
      a: a,
      b: b,
      template_a: template_a
    } do
      assert {:error, :not_found} =
               Templates.update_template(b.id, template_a.id, %{body: "sequestrado"})

      assert {:error, :not_found} = Templates.deactivate_template(b.id, template_a.id)
      assert {:error, :not_found} = Templates.activate_template(b.id, template_a.id)

      untouched = Templates.get_template(a.id, template_a.id)
      assert untouched.active
      assert untouched.body == template_a.body
    end

    test "both tenants can have an active template for the same event type", %{a: a, b: b} do
      assert {:ok, _} = Templates.create_template(b.id, %{@valid | event_type: "order_created"})
      assert Templates.find_active(a.id, "order_created")
      assert Templates.find_active(b.id, "order_created")
    end
  end

  describe "render/2 (AC-3)" do
    test "uses the event context and the recipient's name" do
      tenant = tenant!()

      template =
        template!(tenant, %{
          body: "{{recipient_name}}: pedido {{numero_pedido}} / {{nome_cliente}}"
        })

      assert {:ok, "Maria da Silva: pedido 1234 / Maria da Silva"} =
               Templates.render(template, canonical_payload())
    end

    test "falls back to the default when the event has no name" do
      tenant = tenant!()
      template = template!(tenant)

      payload =
        canonical_payload(%{
          "recipient" => %{"name" => nil, "phone" => "+5511999998888"},
          "context" => %{"numero_pedido" => "77", "nome_cliente" => nil}
        })

      assert {:ok, "Olá cliente, seu pedido 77 foi recebido."} =
               Templates.render(template, payload)
    end

    test "fails, naming the variable, when the event lacks a required value" do
      tenant = tenant!()
      template = template!(tenant, %{body: "Pedido {{numero_pedido}}"})

      assert {:error, {:missing_variable, "numero_pedido"}} =
               Templates.render(template, canonical_payload(%{"context" => %{}}))
    end

    test "does not expose the phone number as a variable" do
      tenant = tenant!()

      template =
        template!(tenant, %{body: "Seu número: {{phone|oculto}} {{recipient_phone|oculto}}"})

      assert {:ok, "Seu número: oculto oculto"} = Templates.render(template, canonical_payload())
    end

    test "tolerates a payload with no context or recipient" do
      tenant = tenant!()
      template = template!(tenant, %{body: "Olá {{recipient_name|cliente}}"})

      assert {:ok, "Olá cliente"} = Templates.render(template, %{})
      assert {:ok, "Olá cliente"} = Templates.render(template, %{"context" => "not a map"})
    end
  end

  describe "EventTypes (AC-13)" do
    test "lists the five canonical types" do
      assert Enum.sort(EventTypes.all()) ==
               Enum.sort(
                 ~w(order_created order_invoiced order_shipped auth_code_requested marketing_campaign_triggered)
               )
    end

    test "valid?/1 accepts only those" do
      assert EventTypes.valid?("order_invoiced")

      for other <- ["Order_Created", "order_teleported", "", nil, :order_created, 1] do
        refute EventTypes.valid?(other), inspect(other)
      end
    end

    test "every type the Bling adapter emits is a known type" do
      assert EventTypes.valid?("order_invoiced")
      assert EventTypes.valid?("order_shipped")
    end
  end
end
