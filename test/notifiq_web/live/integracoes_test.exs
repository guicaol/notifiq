defmodule NotifiqWeb.PainelLive.IntegracoesTest do
  # Not async: one test narrows the registered sources through the application env.
  use NotifiqWeb.ConnCase, async: false

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Tenants

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  defp connect_account(view, source, account) do
    view
    |> form("#integration-form", integration: %{source: source, external_account_id: account})
    |> render_submit()
  end

  defp active_account?(tenant, account) do
    tenant.id
    |> Tenants.list_integrations()
    |> Enum.any?(&(&1.external_account_id == account and &1.status == "active"))
  end

  test "AC-6: needs a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel/integracoes")
  end

  describe "the page" do
    test "lists the tenant's own integrations with the source's name", %{conn: conn} do
      tenant = tenant!()
      mine = integration!(tenant, "fake", "mine-1")

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      assert has_element?(view, "#integrations-#{mine.id}", "Fonte Fake")
      assert has_element?(view, "#integrations-#{mine.id}", "mine-1")
      assert has_element?(view, "#nav-integracoes[aria-current=page]")
    end

    test "AC-10: never lists another tenant's integrations", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!()
      other = integration!(theirs, "fake", "their-secret-account")

      {:ok, view, html} = live(signed_in(conn, mine), ~p"/painel/integracoes")

      refute html =~ "their-secret-account"
      refute has_element?(view, "#integrations-#{other.id}")
      assert has_element?(view, "#integrations-empty")
    end

    test "AC-11: source names, labels and webhook URLs come from the adapters", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/integracoes")

      for {key, module} <- Notifiq.Integrations.Registry.sources() do
        %{name: name} = module.metadata()
        assert has_element?(view, "#webhook-url-#{key}", name)
        assert has_element?(view, "#webhook-url-#{key}", "/api/webhooks/#{key}")
      end

      assert has_element?(view, "#integration-source")
      assert has_element?(view, "#integration-account")
    end
  end

  describe "connecting (AC-11)" do
    test "connects an account to the signed-in tenant and shows it", %{conn: conn} do
      tenant = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      html = connect_account(view, "fake", "  new-account  ")

      assert html =~ "Conta conectada."
      assert active_account?(tenant, "new-account")
      assert has_element?(view, "#integrations li", "new-account")
    end

    test "a blank account is refused with a message and nothing is stored", %{conn: conn} do
      tenant = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      html = connect_account(view, "fake", "   ")

      assert html =~ "Informe o identificador da conta."
      assert Tenants.list_integrations(tenant.id) == []
    end

    test "an unregistered source is refused", %{conn: conn} do
      tenant = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      render_submit(view, "connect", %{
        "integration" => %{"source" => "does_not_exist", "external_account_id" => "x"}
      })

      assert Tenants.list_integrations(tenant.id) == []
      assert render(view) =~ "Escolha uma das fontes disponíveis."
    end

    test "the browser can't choose the tenant or the status", %{conn: conn} do
      tenant = tenant!()
      victim = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      render_submit(view, "connect", %{
        "integration" => %{
          "source" => "fake",
          "external_account_id" => "forged",
          "tenant_id" => victim.id,
          "status" => "disabled"
        }
      })

      assert [%{tenant_id: tenant_id, status: "active"}] = Tenants.list_integrations(tenant.id)
      assert tenant_id == tenant.id
      assert Tenants.list_integrations(victim.id) == []
    end

    test "AC-10: an account held by another tenant gets the generic error, no leak", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!(0, "Loja Vizinha")
      integration!(theirs, "fake", "taken-account")

      {:ok, view, _html} = live(signed_in(conn, mine), ~p"/painel/integracoes")

      html = connect_account(view, "fake", "taken-account")

      assert html =~ "Esta conta já está conectada."
      refute html =~ "Loja Vizinha"
      assert Tenants.list_integrations(mine.id) == []
      assert active_account?(theirs, "taken-account")
    end

    test "the same account twice by the same tenant gets the same error", %{conn: conn} do
      tenant = tenant!()
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      connect_account(view, "fake", "dup")
      html = connect_account(view, "fake", "dup")

      assert html =~ "Esta conta já está conectada."
      assert length(Tenants.list_integrations(tenant.id)) == 1
    end

    test "a malformed submission doesn't crash the page", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/integracoes")

      assert render_submit(view, "connect", %{"integration" => "nonsense"}) =~ "Integrações"
      assert render_submit(view, "connect", %{}) =~ "Integrações"
    end
  end

  describe "disconnecting (AC-11, AC-10)" do
    test "disconnects the tenant's own integration and frees the account", %{conn: conn} do
      tenant = tenant!()
      mine = integration!(tenant, "fake", "mine")
      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      html = view |> element("#disconnect-#{mine.id}") |> render_click()

      assert html =~ "Conta desconectada."
      refute active_account?(tenant, "mine")
      refute has_element?(view, "#disconnect-#{mine.id}")
      assert has_element?(view, "#integrations-#{mine.id}", "Desconectada")

      # The account is free for someone else now.
      assert {:ok, _} =
               Tenants.connect_integration(tenant!().id, %{
                 source: "fake",
                 external_account_id: "mine"
               })
    end

    test "another tenant's integration id changes nothing", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!()
      other = integration!(theirs, "fake", "their-account")
      {:ok, view, _html} = live(signed_in(conn, mine), ~p"/painel/integracoes")

      html = render_click(view, "disconnect", %{"id" => other.id})

      assert html =~ "Integração não encontrada."
      assert active_account?(theirs, "their-account")
    end

    test "a malformed or unknown id is just 'not found'", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/integracoes")

      for id <- ["not-a-uuid", Ecto.UUID.generate(), "", "1' OR '1'='1"] do
        assert render_click(view, "disconnect", %{"id" => id}) =~ "Integração não encontrada."
      end
    end
  end

  describe "with a single registered source" do
    setup do
      original = Application.get_env(:notifiq, :integration_sources)
      Application.put_env(:notifiq, :integration_sources, %{"fake" => Notifiq.Test.FakeSource})
      on_exit(fn -> Application.put_env(:notifiq, :integration_sources, original) end)
    end

    test "hides the source picker and uses the adapter's label", %{conn: conn} do
      tenant = tenant!()
      {:ok, view, html} = live(signed_in(conn, tenant), ~p"/painel/integracoes")

      assert html =~ "Conta da fonte fake"
      refute has_element?(view, "select#integration-source")

      render_submit(view, "connect", %{
        "integration" => %{"source" => "fake", "external_account_id" => "solo"}
      })

      assert active_account?(tenant, "solo")
    end
  end

  describe "without any registered source" do
    setup do
      original = Application.get_env(:notifiq, :integration_sources)
      Application.put_env(:notifiq, :integration_sources, %{})
      on_exit(fn -> Application.put_env(:notifiq, :integration_sources, original) end)
    end

    test "says so instead of showing a form", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/integracoes")

      assert has_element?(view, "#no-sources")
      refute has_element?(view, "#integration-form")
    end
  end
end
