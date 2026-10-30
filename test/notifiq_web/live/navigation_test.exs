defmodule NotifiqWeb.PainelLive.NavigationTest do
  # Spec 011: the menu (FR-1, AC-1) and the shortcuts from the summary (FR-18, AC-13).
  use NotifiqWeb.ConnCase, async: true

  import Ecto.Query
  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Mensageria.WebhookEvent
  alias Notifiq.Repo

  @entries [
    resumo: "/painel",
    mensagens: "/painel/mensagens",
    templates: "/painel/templates",
    creditos: "/painel/creditos",
    integracoes: "/painel/integracoes"
  ]

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  describe "the menu (AC-1)" do
    test "has the five entries, in order, on every page, and marks the current one", %{conn: conn} do
      conn = signed_in(conn, tenant!(3))

      for {current, path} <- @entries do
        {:ok, view, html} = live(conn, path)

        for {key, href} <- @entries do
          assert has_element?(view, "#nav-#{key}[href='#{href}']"), "#{key} missing on #{path}"
        end

        assert has_element?(view, "#nav-#{current}[aria-current=page]")

        others = Keyword.keys(@entries) -- [current]
        refute Enum.any?(others, &has_element?(view, "#nav-#{&1}[aria-current=page]"))

        positions =
          for {key, _} <- @entries, do: :binary.match(html, ~s(id="nav-#{key}")) |> elem(0)

        assert positions == Enum.sort(positions), "menu out of order on #{path}"
      end
    end

    test "the form and detail pages keep their section highlighted", %{conn: conn} do
      tenant = tenant!(3)
      log = reserve!(tenant)
      template = template!(tenant)
      conn = signed_in(conn, tenant)

      {:ok, view, _html} = live(conn, "/painel/mensagens/#{log.id}")
      assert has_element?(view, "#nav-mensagens[aria-current=page]")

      {:ok, view, _html} = live(conn, "/painel/templates/novo?tipo=order_shipped")
      assert has_element?(view, "#nav-templates[aria-current=page]")

      {:ok, view, _html} = live(conn, "/painel/templates/#{template.id}/editar")
      assert has_element?(view, "#nav-templates[aria-current=page]")
    end

    test "walking from one page to the next keeps the session", %{conn: conn} do
      conn = signed_in(conn, tenant!())
      {:ok, view, _html} = live(conn, ~p"/painel")

      result = view |> element("#nav-mensagens") |> render_click()
      assert {:error, {:live_redirect, %{to: "/painel/mensagens"}}} = result

      {:ok, view, _html} = follow_redirect(result, conn)
      assert has_element?(view, "#nav-mensagens[aria-current=page]")
    end
  end

  describe "shortcuts on the summary (AC-13)" do
    test "the statement and the full history are one click away", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel")

      assert has_element?(view, "#link-creditos[href='/painel/creditos']")
      assert has_element?(view, "#link-mensagens[href='/painel/mensagens']")
    end

    test "failures link to the failed messages, and only when there are some", %{conn: conn} do
      tenant = tenant!(5)
      conn = signed_in(conn, tenant)

      {:ok, view, _html} = live(conn, ~p"/painel")
      refute has_element?(view, "#link-failed")

      log = reserve!(tenant)
      Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [status: "failed"])

      {:ok, view, _html} = live(conn, ~p"/painel")
      assert has_element?(view, "#link-failed[href='/painel/mensagens?situacao=failed']")
    end

    test "'no template' leads to the templates, the other problems don't", %{conn: conn} do
      tenant = tenant!(5)
      conn = signed_in(conn, tenant)

      for status <- ["skipped_no_template", "insufficient_credits"] do
        event = event!(tenant)

        Repo.update_all(from(e in WebhookEvent, where: e.id == ^event.id),
          set: [status: status]
        )
      end

      {:ok, view, _html} = live(conn, ~p"/painel")

      assert has_element?(view, "#problem-link-skipped_no_template[href='/painel/templates']")
      refute has_element?(view, "#problem-link-insufficient_credits")
    end
  end
end
