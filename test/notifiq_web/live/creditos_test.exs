defmodule NotifiqWeb.PainelLive.CreditosTest do
  # Spec 011, FR-15/16/17 (AC-1, AC-12).
  use NotifiqWeb.ConnCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Mensageria

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#entries tr[id^='entry-']")
    |> Enum.count()
  end

  test "AC-1: needs a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel/creditos")
  end

  describe "the statement" do
    test "shows the balance, the nav and the way to recharge", %{conn: conn} do
      tenant = tenant!(1_234)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/creditos")

      assert text(view, "#balance") == "1.234"
      assert has_element?(view, "#nav-creditos[aria-current=page]")
      assert has_element?(view, "#recharge-note", "quem administra a plataforma")
      refute has_element?(view, "a", "Comprar")
    end

    test "lists the entries with signed amounts and the balance after each", %{conn: conn} do
      tenant = tenant!(10)
      log = reserve!(tenant)
      {:ok, _} = Mensageria.give_up(log, :stale)
      reserve!(tenant)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/creditos")

      {entries, nil} = Mensageria.page_credit_transactions(tenant.id)
      assert rows(view) == length(entries)
      assert rows(view) == 4

      for %{transaction: entry, balance_after: balance_after} <- entries do
        assert text(view, "#balance-after-#{entry.id}") == to_string(balance_after)
      end

      # Newest first: the last debit leaves the balance the tenant has now.
      [%{transaction: newest} | _] = entries
      assert text(view, "#balance-after-#{newest.id}") == text(view, "#balance")
      assert text(view, "#amount-#{newest.id}") == "−1"
    end

    test "names each reason in Portuguese", %{conn: conn} do
      tenant = tenant!(10)
      log = reserve!(tenant)
      {:ok, _} = Mensageria.give_up(log, :stale)
      {:ok, _} = Mensageria.add_credits(tenant.id, 5, "purchase")

      {:ok, _view, html} = live(signed_in(conn, tenant), ~p"/painel/creditos")

      assert html =~ "Ajuste"
      assert html =~ "Envio de mensagem"
      assert html =~ "Estorno de envio"
      assert html =~ "Compra de créditos"
    end

    test "entries tied to a message link to it, the others don't", %{conn: conn} do
      tenant = tenant!(10)
      log = reserve!(tenant)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/creditos")

      {entries, nil} = Mensageria.page_credit_transactions(tenant.id)
      dispatch = Enum.find(entries, &(&1.transaction.reason == "dispatch")).transaction
      adjustment = Enum.find(entries, &(&1.transaction.reason == "adjustment")).transaction

      assert has_element?(
               view,
               "#entry-message-#{dispatch.id}[href='/painel/mensagens/#{log.id}']"
             )

      refute has_element?(view, "#entry-message-#{adjustment.id}")
    end

    test "AC-12: only the tenant's own entries", %{conn: conn} do
      mine = tenant!(10)
      theirs = tenant!(777)
      reserve!(theirs)

      {:ok, view, html} = live(signed_in(conn, mine), ~p"/painel/creditos")

      assert rows(view) == 1
      assert text(view, "#balance") == "10"
      refute html =~ "776"
      refute html =~ "777"
    end

    test "a tenant with no entries sees an empty state", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!(0)), ~p"/painel/creditos")

      assert has_element?(view, "#entries-empty")
      assert text(view, "#balance") == "0"
      refute has_element?(view, "#load-more")
    end
  end

  describe "load more" do
    test "25 at a time, then the rest, closing with the balance", %{conn: conn} do
      tenant = tenant!(40)
      for _ <- 1..29, do: reserve!(tenant)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/creditos")

      assert rows(view) == 25
      assert has_element?(view, "#load-more")

      view |> element("#load-more") |> render_click()

      assert rows(view) == 30
      refute has_element?(view, "#load-more")

      {entries, _} = Mensageria.page_credit_transactions(tenant.id, limit: 100)

      for %{transaction: entry, balance_after: balance_after} <- entries do
        assert text(view, "#balance-after-#{entry.id}") == to_string(balance_after)
      end
    end

    test "asking for more with nothing more is harmless", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!(3)), ~p"/painel/creditos")

      assert render_click(view, "more") =~ "Créditos"
    end
  end
end
