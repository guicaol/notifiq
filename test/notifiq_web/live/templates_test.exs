defmodule NotifiqWeb.PainelLive.TemplatesTest do
  # Spec 011, FR-4/10 (AC-1, AC-2, AC-7).
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

  # A template the domain would refuse to create today, to see how the page copes.
  defp legacy_template!(tenant, attrs) do
    Repo.insert!(
      struct!(
        MessageTemplate,
        Map.merge(
          %{
            tenant_id: tenant.id,
            event_type: "order_created",
            channel: "sms",
            provider: "fake_sms",
            body: "texto",
            cost: 1,
            active: true
          },
          attrs
        )
      )
    )
  end

  test "AC-1: needs a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel/templates")
  end

  describe "the page (AC-2)" do
    test "has one card per event type, with the nav highlighted", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/templates")

      for type <- EventTypes.all() do
        assert has_element?(view, "#type-#{type}")
        assert has_element?(view, "#create-#{type}[href='/painel/templates/novo?tipo=#{type}']")
      end

      assert has_element?(view, "#nav-templates[aria-current=page]")
      assert has_element?(view, "#type-order_invoiced", "Sem template")
      assert has_element?(view, "#type-order_invoiced", "Pedido faturado")
    end

    test "an active template shows the text as the customer reads it, and its cost", %{conn: conn} do
      tenant = tenant!()

      template =
        template!(tenant, %{
          event_type: "order_invoiced",
          body: "Olá {{nome_cliente}}, pedido {{numero_pedido}} faturado.",
          cost: 2
        })

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      assert has_element?(
               view,
               "#template-#{template.id}",
               "Olá Maria Silva, pedido 4321 faturado."
             )

      assert has_element?(view, "#template-#{template.id}", "2 créditos")
      assert has_element?(view, "#template-#{template.id}", "SMS · fake_sms")
      assert has_element?(view, "#type-order_invoiced", "Ativo")
      refute has_element?(view, "#create-order_invoiced")

      assert has_element?(
               view,
               "#edit-#{template.id}[href='/painel/templates/#{template.id}/editar']"
             )

      assert has_element?(view, "#deactivate-#{template.id}")
    end

    test "a single credit is not pluralised", %{conn: conn} do
      tenant = tenant!()
      template!(tenant, %{event_type: "order_invoiced", cost: 1})

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      assert has_element?(view, "#type-order_invoiced", "1 crédito por")
    end

    test "switched-off templates are listed under their type", %{conn: conn} do
      tenant = tenant!()
      old = template!(tenant, %{event_type: "order_shipped", body: "Texto antigo"})
      {:ok, _} = Templates.deactivate_template(tenant.id, old.id)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      assert has_element?(view, "#inactive-order_shipped #template-#{old.id}", "Texto antigo")
      assert has_element?(view, "#activate-#{old.id}")
      assert has_element?(view, "#type-order_shipped", "Sem template")
    end

    test "AC-2: never shows another tenant's templates", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!()
      other = template!(theirs, %{body: "texto confidencial do vizinho"})

      {:ok, view, html} = live(signed_in(conn, mine), ~p"/painel/templates")

      refute html =~ "confidencial"
      refute has_element?(view, "#template-#{other.id}")
      assert has_element?(view, "#type-order_created", "Sem template")
    end

    test "a template that uses a variable that no longer exists doesn't break the page", %{
      conn: conn
    } do
      tenant = tenant!()
      template = legacy_template!(tenant, %{body: "Oi {{fantasma}}"})

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      assert has_element?(view, "#template-#{template.id}", "variável que não existe mais")
    end
  end

  describe "deactivating (AC-7)" do
    test "switches the template off and offers to create another", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_invoiced"})
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      html = view |> element("#deactivate-#{template.id}") |> render_click()

      assert html =~ "Template desativado."
      assert Templates.find_active(tenant.id, "order_invoiced") == nil
      assert has_element?(view, "#create-order_invoiced")
      assert has_element?(view, "#activate-#{template.id}")
      refute has_element?(view, "#deactivate-#{template.id}")
    end

    test "another tenant's template is 'not found' and stays active", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!()
      other = template!(theirs)
      {:ok, view, _html} = live(signed_in(conn, mine), ~p"/painel/templates")

      assert render_click(view, "deactivate", %{"id" => other.id}) =~ "Template não encontrado."
      assert Templates.find_active(theirs.id, "order_created")
    end

    test "a malformed or unknown id is just 'not found'", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/templates")

      for id <- ["nope", "", Ecto.UUID.generate(), "1' OR '1'='1"] do
        assert render_click(view, "deactivate", %{"id" => id}) =~ "Template não encontrado."
        assert render_click(view, "activate", %{"id" => id}) =~ "Template não encontrado."
      end
    end
  end

  describe "activating (AC-7)" do
    test "switches a template back on", %{conn: conn} do
      tenant = tenant!()
      template = template!(tenant, %{event_type: "order_invoiced"})
      {:ok, _} = Templates.deactivate_template(tenant.id, template.id)
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      html = view |> element("#activate-#{template.id}") |> render_click()

      assert html =~ "Template ativado."
      assert %{id: id} = Templates.find_active(tenant.id, "order_invoiced")
      assert id == template.id
      assert has_element?(view, "#deactivate-#{template.id}")
    end

    test "with another one active for the type it warns and changes nothing", %{conn: conn} do
      tenant = tenant!()
      old = template!(tenant, %{event_type: "order_invoiced", body: "Antigo"})
      {:ok, _} = Templates.deactivate_template(tenant.id, old.id)
      current = template!(tenant, %{event_type: "order_invoiced", body: "Atual"})
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/templates")

      html = view |> element("#activate-#{old.id}") |> render_click()

      assert html =~ "Já existe um template ativo"
      assert %{id: id} = Templates.find_active(tenant.id, "order_invoiced")
      assert id == current.id
      assert has_element?(view, "#activate-#{old.id}")
    end

    test "another tenant's template can't be switched on", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!()
      other = template!(theirs)
      {:ok, _} = Templates.deactivate_template(theirs.id, other.id)
      {:ok, view, _html} = live(signed_in(conn, mine), ~p"/painel/templates")

      assert render_click(view, "activate", %{"id" => other.id}) =~ "Template não encontrado."
      assert Templates.find_active(theirs.id, "order_created") == nil
    end
  end

  test "the text of a card is not interpreted as markup", %{conn: conn} do
    tenant = tenant!()
    template = legacy_template!(tenant, %{body: "<script>alert(1)</script> {{recipient_name}}"})

    {:ok, view, html} = live(signed_in(conn, tenant), ~p"/painel/templates")

    refute html =~ "<script>alert(1)"
    assert text(view, "#template-#{template.id}") =~ "alert(1)"
  end
end
