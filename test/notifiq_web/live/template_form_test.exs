defmodule NotifiqWeb.PainelLive.TemplateFormTest do
  # Spec 011, FR-5 to FR-9 (AC-1, AC-3 to AC-9).
  use NotifiqWeb.ConnCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Mensageria.EventTypes
  alias Notifiq.Repo
  alias Notifiq.Templates
  alias Notifiq.Templates.MessageTemplate

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp valid_params(overrides) do
    Map.merge(
      %{
        "event_type" => "order_invoiced",
        "delivery" => "fake_sms:sms",
        "body" => "Olá {{nome_cliente|cliente}}, seu pedido {{numero_pedido}} foi faturado.",
        "cost" => "2"
      },
      overrides
    )
  end

  # Sends the event as a hand-made request would, so that values the form's own select would
  # never offer (and fields it does not show) can be tried too.
  defp submit(view, overrides \\ %{}) do
    render_submit(view, "save", %{"template" => valid_params(overrides)})
  end

  defp stored(tenant), do: Templates.list_templates(tenant.id)

  defp assert_saved(result, conn, flash) do
    assert {:error, {:live_redirect, %{to: "/painel/templates"}}} = result
    {:ok, _view, html} = follow_redirect(result, conn)
    assert html =~ flash
  end

  describe "access (AC-1)" do
    test "every form route needs a session", %{conn: conn} do
      id = Ecto.UUID.generate()

      for path <- ["/painel/templates/novo", "/painel/templates/#{id}/editar"] do
        assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, path)
      end
    end
  end

  describe "the new template form" do
    test "offers the types without an active template, the registered ways to send and the variables",
         %{conn: conn} do
      tenant = tenant!()
      template!(tenant, %{event_type: "order_invoiced"})

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/novo")

      refute has_element?(view, "#template-event-type option[value=order_invoiced]")

      for type <- EventTypes.all() -- ["order_invoiced"] do
        assert has_element?(view, "#template-event-type option[value=#{type}]")
      end

      for value <- ["fake_sms:sms", "fake_multi:sms", "fake_multi:whatsapp", "twilio:sms"] do
        assert has_element?(view, "#template-delivery option[value='#{value}']")
      end

      assert has_element?(view, "#template-delivery option", "SMS · fake_sms")
      assert has_element?(view, "#template-delivery option", "WhatsApp · fake_multi")

      for name <- ["recipient_name", "numero_pedido", "nome_cliente", "codigo_rastreio"] do
        assert has_element?(view, "#variable-#{name}", "{{#{name}}}")
      end

      assert has_element?(view, "#nav-templates[aria-current=page]")
    end

    test "AC-9: a variable button inserts its token where the cursor is", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/templates/novo")

      assert has_element?(view, "#variable-numero_pedido[phx-click*='phx:insert']")
      assert has_element?(view, "#variable-numero_pedido[phx-click*='#template-body']")
      assert has_element?(view, "#variable-numero_pedido[phx-click*='{{numero_pedido}}']")
    end

    test "?tipo= preselects a type that can be created, and ignores any other", %{conn: conn} do
      tenant = tenant!()
      template!(tenant, %{event_type: "order_shipped"})
      conn = signed_in(conn, tenant)

      {:ok, view, _html} = live(conn, ~p"/painel/templates/novo?tipo=order_created")
      assert has_element?(view, "#template-event-type option[value=order_created][selected]")

      for query <- ["tipo=order_shipped", "tipo=nope", "tipo[]=x", "tipo="] do
        {:ok, view, _html} = live(conn, "/painel/templates/novo?" <> query)
        refute has_element?(view, "#template-event-type option[value=order_shipped]")
        assert has_element?(view, "#template-event-type option[selected]")
      end
    end

    test "when every type already has an active template it sends the merchant back", %{
      conn: conn
    } do
      tenant = tenant!()
      for type <- EventTypes.all(), do: template!(tenant, %{event_type: type})
      conn = signed_in(conn, tenant)

      assert {:error, {:live_redirect, %{to: "/painel/templates"}}} =
               result = live(conn, ~p"/painel/templates/novo")

      {:ok, _view, html} = follow_redirect(result, conn)
      assert html =~ "Todos os tipos de evento já têm um template ativo."
    end
  end

  describe "creating (AC-3)" do
    test "stores an active template of the signed-in tenant", %{conn: conn} do
      tenant = tenant!()
      conn = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel/templates/novo")

      # Through the form itself, field names and all.
      result =
        view
        |> form("#template-form", template: valid_params(%{}))
        |> render_submit()

      assert_saved(result, conn, "Template criado.")

      assert [template] = stored(tenant)
      assert template.tenant_id == tenant.id
      assert template.active
      assert template.event_type == "order_invoiced"
      assert {template.provider, template.channel} == {"fake_sms", "sms"}
      assert template.cost == 2
      assert template.body =~ "{{numero_pedido}}"
    end

    test "a provider that carries several channels is chosen together with the channel", %{
      conn: conn
    } do
      tenant = tenant!()
      conn = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel/templates/novo")

      assert_saved(submit(view, %{"delivery" => "fake_multi:whatsapp"}), conn, "Template criado.")

      assert [%{provider: "fake_multi", channel: "whatsapp"}] = stored(tenant)
    end

    test "the browser can't choose the tenant, the active flag or the provider apart from the pair",
         %{conn: conn} do
      tenant = tenant!()
      victim = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/novo")

      render_submit(view, "save", %{
        "template" =>
          valid_params(%{
            "tenant_id" => victim.id,
            "active" => "false",
            "provider" => "twilio",
            "channel" => "whatsapp"
          })
      })

      assert [template] = stored(tenant)
      assert template.tenant_id == tenant.id
      assert template.active
      assert {template.provider, template.channel} == {"fake_sms", "sms"}
      assert stored(victim) == []
    end
  end

  describe "validation (AC-4)" do
    setup %{conn: conn} do
      tenant = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/novo")
      %{view: view, tenant: tenant}
    end

    test "an empty text", %{view: view, tenant: tenant} do
      html = submit(view, %{"body" => ""})

      assert html =~ "Preencha este campo."
      assert stored(tenant) == []
    end

    test "a text of only spaces", %{view: view, tenant: tenant} do
      assert submit(view, %{"body" => "     "}) =~ "Preencha este campo."
      assert stored(tenant) == []
    end

    test "a text that is too long, with the limit", %{view: view, tenant: tenant} do
      html = submit(view, %{"body" => String.duplicate("a", 1001)})

      assert html =~ "Use no máximo 1000 caracteres."
      assert stored(tenant) == []
    end

    test "the longest text is accepted", %{view: view, tenant: tenant} do
      submit(view, %{"body" => String.duplicate("a", 1000)})

      assert [_template] = stored(tenant)
    end

    test "a malformed variable", %{view: view, tenant: tenant} do
      for body <- ["Olá {{nome", "Olá nome}}", "Olá {{}}", "Olá {{1x}}"] do
        assert submit(view, %{"body" => body}) =~ "Há uma variável mal escrita", body
      end

      assert stored(tenant) == []
    end

    test "a variable nobody provides, with its name", %{view: view, tenant: tenant} do
      html = submit(view, %{"body" => "Olá {{nome}}, pedido {{pedido}}"})

      assert html =~ "Variável que não existe: {{nome}}, {{pedido}}."
      assert stored(tenant) == []
    end

    test "a default doesn't excuse a variable nobody provides", %{view: view, tenant: tenant} do
      assert submit(view, %{"body" => "Olá {{apelido|cliente}}"}) =~ "Variável que não existe"
      assert stored(tenant) == []
    end

    test "a cost outside 1 to 10, or not a number", %{view: view, tenant: tenant} do
      for cost <- ["0", "11", "-3", "abc", "1.5", ""] do
        html = submit(view, %{"cost" => cost})
        assert html =~ "Use um número inteiro de 1 a 10." or html =~ "Preencha este campo.", cost
      end

      assert stored(tenant) == []
    end

    test "a way to send that isn't registered", %{view: view, tenant: tenant} do
      for delivery <- ["", "nope:sms", "fake_sms:whatsapp", "twilio", "fake_sms:sms:extra"] do
        assert submit(view, %{"delivery" => delivery}) =~ "Escolha como enviar.", delivery
      end

      assert stored(tenant) == []
    end

    test "provider and channel typed by hand don't replace the choice of how to send", %{
      view: view,
      tenant: tenant
    } do
      for delivery <- ["", "nope:sms"] do
        html =
          submit(view, %{"delivery" => delivery, "provider" => "fake_sms", "channel" => "sms"})

        assert html =~ "Escolha como enviar.", delivery
      end

      assert stored(tenant) == []
    end

    test "an event type that isn't one", %{view: view, tenant: tenant} do
      assert submit(view, %{"event_type" => "order_teleported"}) =~ "Escolha um tipo de evento"
      assert stored(tenant) == []
    end

    test "errors are in Portuguese, never the changeset's English", %{view: view} do
      html = submit(view, %{"body" => "", "cost" => "99"})

      refute html =~ "can't be blank"
      refute html =~ "is invalid"
      refute html =~ "must be"
    end

    test "garbage in the event doesn't crash the form", %{view: view} do
      assert render_change(view, "validate", %{"template" => "nonsense"}) =~ "template"
      assert render_submit(view, "save", %{"template" => "nonsense"}) =~ "template"
      assert render_submit(view, "save", %{}) =~ "template"

      assert render_submit(view, "save", %{
               "template" => %{"body" => %{"a" => "b"}, "cost" => [1]}
             }) =~
               "template"
    end
  end

  describe "one active template per type (AC-5)" do
    test "forging a type that already has one is refused and keeps a single active", %{conn: conn} do
      tenant = tenant!()
      existing = template!(tenant, %{event_type: "order_invoiced", body: "Primeiro"})
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/novo")

      html =
        render_submit(view, "save", %{
          "template" => valid_params(%{"event_type" => "order_invoiced"})
        })

      assert html =~ "Já existe um template ativo para este tipo de evento."
      assert [only] = stored(tenant)
      assert only.id == existing.id
    end
  end

  describe "the preview (AC-8)" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/templates/novo")
      %{view: view}
    end

    defp type(view, body) do
      view
      |> form("#template-form", template: valid_params(%{"body" => body}))
      |> render_change()
    end

    test "starts empty", %{view: view} do
      assert has_element?(view, "#preview-empty")
    end

    test "fills the text with the sources' examples as the merchant types", %{view: view} do
      type(view, "Olá {{nome_cliente}}, pedido {{numero_pedido}}.")

      assert text(view, "#preview-text") =~ "Olá Maria Silva, pedido 4321."
      assert text(view, "#preview-count") == "29 caracteres"
      assert text(view, "#body-count") == "47/1000"
      refute has_element?(view, "#preview-warning")
    end

    test "uses the default for a variable the sources don't carry... and warns for no default",
         %{view: view} do
      type(view, "Oi {{recipient_name|cliente}}")
      assert text(view, "#preview-text") =~ "Oi Maria Silva"

      type(view, "Oi {{nome}}")
      assert text(view, "#preview-warning") =~ "A variável {{nome}} não existe."
      refute has_element?(view, "#preview-text")
    end

    test "warns about broken braces instead of crashing", %{view: view} do
      type(view, "Oi {{nome")

      assert text(view, "#preview-warning") =~ "As chaves estão incorretas"
    end

    test "never shows a real customer", %{conn: conn} do
      tenant = tenant!()

      event!(
        tenant,
        "evt",
        canonical_payload(%{
          "recipient" => %{"name" => "Cliente Verdadeiro", "phone" => "+5511977776666"}
        })
      )

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/novo")
      type(view, "{{recipient_name}}")

      refute render(view) =~ "Cliente Verdadeiro"
      assert text(view, "#preview-text") =~ "Maria Silva"
    end

    test "shows no error before the merchant has typed in a field", %{view: view} do
      refute render(view) =~ "Preencha este campo."
    end

    test "an error appears as the merchant types", %{view: view} do
      html = type(view, "Oi {{nome}}")

      assert html =~ "Variável que não existe: {{nome}}."
    end
  end

  describe "editing (AC-6)" do
    test "loads the template into the form", %{conn: conn} do
      tenant = tenant!()

      template =
        template!(tenant, %{event_type: "order_shipped", body: "Saiu {{numero_pedido}}", cost: 3})

      {:ok, view, _html} =
        live(signed_in(conn, tenant), ~p"/painel/templates/#{template.id}/editar")

      assert has_element?(view, "#template-body", "Saiu {{numero_pedido}}")
      assert has_element?(view, "#template-cost[value='3']")
      assert has_element?(view, "#template-delivery option[value='fake_sms:sms'][selected]")
      assert text(view, "#template-event-type-fixed") == "Pedido enviado"
      refute has_element?(view, "#template-event-type")
      assert text(view, "#preview-text") =~ "Saiu 4321"
      assert has_element?(view, "#template-submit", "Salvar alterações")
    end

    test "saves the changes and keeps the template active", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_shipped"})
      conn = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel/templates/#{template.id}/editar")

      result =
        view
        |> form("#template-form",
          template: %{
            "body" => "Novo texto {{numero_pedido}}",
            "cost" => "5",
            "delivery" => "fake_multi:whatsapp"
          }
        )
        |> render_submit()

      assert_saved(result, conn, "Template salvo.")

      assert [saved] = stored(tenant)
      assert saved.id == template.id
      assert saved.body == "Novo texto {{numero_pedido}}"
      assert saved.cost == 5
      assert {saved.provider, saved.channel} == {"fake_multi", "whatsapp"}
      assert saved.active
    end

    test "the type can't be changed, even by forging the field", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_shipped"})

      {:ok, view, _html} =
        live(signed_in(conn, tenant), ~p"/painel/templates/#{template.id}/editar")

      render_submit(view, "save", %{
        "template" =>
          valid_params(%{"event_type" => "order_created", "tenant_id" => Ecto.UUID.generate()})
      })

      assert [%{event_type: "order_shipped", tenant_id: tenant_id}] = stored(tenant)
      assert tenant_id == tenant.id
    end

    test "shows the same errors as the creation and saves nothing", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_shipped", body: "Original"})

      {:ok, view, _html} =
        live(signed_in(conn, tenant), ~p"/painel/templates/#{template.id}/editar")

      assert submit(view, %{"body" => "Oi {{nome}}"}) =~ "Variável que não existe"
      assert submit(view, %{"cost" => "50"}) =~ "de 1 a 10"
      assert [%{body: "Original"}] = stored(tenant)
    end

    test "an inactive template can be edited and stays inactive", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_shipped"})
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)
      active = template!(tenant, %{event_type: "order_shipped", body: "Ativo"})
      conn = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel/templates/#{template.id}/editar")

      assert_saved(submit(view, %{"body" => "Ajustado"}), conn, "Template salvo.")

      assert %{body: "Ajustado", active: false} = Templates.get_template(tenant.id, template.id)
      assert Templates.find_active(tenant.id, "order_shipped").id == active.id
    end

    test "a way to send that is no longer registered asks the merchant to choose", %{conn: conn} do
      tenant = tenant!()

      stale =
        Repo.insert!(%MessageTemplate{
          tenant_id: tenant.id,
          event_type: "order_created",
          channel: "sms",
          provider: "retired_provider",
          body: "Oi {{recipient_name}}",
          cost: 1
        })

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates/#{stale.id}/editar")

      assert has_element?(view, "#template-delivery option[value='']", "Escolha...")
      assert submit(view, %{"delivery" => ""}) =~ "Escolha como enviar."
    end
  end

  describe "editing someone else's or nothing (AC-6)" do
    defp assert_not_found(conn, path) do
      assert {:error, {:live_redirect, %{to: "/painel/templates"}}} = result = live(conn, path)
      {:ok, _view, html} = follow_redirect(result, conn)
      assert html =~ "Template não encontrado."
    end

    test "another tenant's template looks like a missing one", %{conn: conn} do
      theirs = tenant!()
      other = template!(theirs, %{body: "texto confidencial do vizinho"})
      conn = signed_in(conn, tenant!())

      assert_not_found(conn, ~p"/painel/templates/#{other.id}/editar")
    end

    test "an unknown or malformed id too", %{conn: conn} do
      conn = signed_in(conn, tenant!())

      assert_not_found(conn, ~p"/painel/templates/#{Ecto.UUID.generate()}/editar")
      assert_not_found(conn, "/painel/templates/nope/editar")
    end

    test "a template that disappears while the form is open ends in 'not found'", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant)

      {:ok, view, _html} =
        live(signed_in(conn, tenant), ~p"/painel/templates/#{template.id}/editar")

      Repo.delete!(template)

      submit(view)
      assert_redirect(view, "/painel/templates")
    end
  end
end
