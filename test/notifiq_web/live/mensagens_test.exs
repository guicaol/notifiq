defmodule NotifiqWeb.PainelLive.MensagensTest do
  # Spec 011, FR-11/12 (AC-1, AC-10).
  use NotifiqWeb.ConnCase, async: true

  import Ecto.Query
  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Repo

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  defp put_status!(log, status) do
    Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [status: status])
    log
  end

  defp stamp!(log, offset_minutes) do
    at = DateTime.add(~U[2026-10-01 00:00:00.000000Z], offset_minutes * 60)
    Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [inserted_at: at])
  end

  # How many message rows the table holds right now.
  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#messages tr[phx-click]")
    |> Enum.count()
  end

  test "AC-1: needs a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel/mensagens")
  end

  describe "the list" do
    test "shows the tenant's messages with the phone masked", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant, %{recipient: "+5511999998888"})

      {:ok, view, html} = live(signed_in(conn, tenant), ~p"/painel/mensagens")

      assert has_element?(view, "#messages-#{log.id}", "+55 ••••• 8888")
      assert has_element?(view, "#messages-#{log.id}", "Na fila")
      assert has_element?(view, "#messages-#{log.id}", "SMS")
      refute html =~ "+5511999998888"
      refute html =~ "999998888"
      assert has_element?(view, "#nav-mensagens[aria-current=page]")
    end

    test "AC-10: never shows another tenant's messages", %{conn: conn} do
      mine = tenant!(5)
      theirs = tenant!(5)
      own = reserve!(mine)
      other = reserve!(theirs, %{recipient: "+5521988887777"})

      {:ok, view, html} = live(signed_in(conn, mine), ~p"/painel/mensagens")

      assert has_element?(view, "#messages-#{own.id}")
      refute has_element?(view, "#messages-#{other.id}")
      refute html =~ "7777"
    end

    test "newest first" do
      tenant = tenant!(5)
      old = reserve!(tenant)
      new = reserve!(tenant)
      stamp!(old, 0)
      stamp!(new, 10)

      {:ok, _view, html} =
        live(signed_in(build_conn(), tenant), ~p"/painel/mensagens")

      assert :binary.match(html, new.id) |> elem(0) < :binary.match(html, old.id) |> elem(0)
    end

    test "says so when there is nothing yet", %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn, tenant!()), ~p"/painel/mensagens")

      assert has_element?(view, "#messages-empty")
      refute has_element?(view, "#load-more")
    end

    test "each row opens the message", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens")

      assert has_element?(view, "#open-#{log.id}[href='/painel/mensagens/#{log.id}']")
    end
  end

  describe "the filter" do
    setup %{conn: conn} do
      tenant = tenant!(20)
      sent = reserve!(tenant) |> put_status!("sent")
      pending = reserve!(tenant)
      failed = reserve!(tenant) |> put_status!("failed")
      unconfirmed = reserve!(tenant) |> put_status!("unconfirmed")

      %{
        conn: signed_in(conn, tenant),
        sent: sent,
        pending: pending,
        failed: failed,
        unconfirmed: unconfirmed
      }
    end

    test "shows everything by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/painel/mensagens")

      assert rows(view) == 4
      assert has_element?(view, "#filter-all[aria-current=true]")
    end

    test "sent, in progress and failed are the same bands as the summary", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens?situacao=sent")
      assert has_element?(view, "#messages-#{ctx.sent.id}")
      assert rows(view) == 1

      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens?situacao=in_progress")
      assert has_element?(view, "#messages-#{ctx.pending.id}")
      assert rows(view) == 1

      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens?situacao=failed")
      assert has_element?(view, "#messages-#{ctx.failed.id}")
      assert has_element?(view, "#messages-#{ctx.unconfirmed.id}")
      assert rows(view) == 2
      assert has_element?(view, "#filter-failed[aria-current=true]")
    end

    test "an unknown filter means all, whatever shape it comes in", %{conn: conn} do
      for query <- ["situacao=falhas", "situacao=", "situacao[]=failed", "situacao[a]=b"] do
        {:ok, view, _html} = live(conn, "/painel/mensagens?" <> query)
        assert rows(view) == 4, query
      end
    end

    test "clicking a filter narrows the list and 'all' brings everything back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/painel/mensagens")

      view |> element("#filter-failed") |> render_click()
      assert rows(view) == 2
      assert_patch(view, ~p"/painel/mensagens?situacao=failed")

      view |> element("#filter-all") |> render_click()
      assert rows(view) == 4
      assert_patch(view, ~p"/painel/mensagens")
    end

    test "a filter with nothing in it says so", %{conn: conn} do
      tenant = tenant!(5)
      reserve!(tenant)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens?situacao=sent")

      assert has_element?(view, "#messages-empty", "nesta situação")
    end
  end

  describe "load more (AC-10)" do
    setup %{conn: conn} do
      tenant = tenant!(40)

      logs =
        for index <- 1..30 do
          log = reserve!(tenant)
          stamp!(log, index)
          log
        end

      %{conn: signed_in(conn, tenant), logs: logs}
    end

    test "25 at a time, then the rest, with no repeats", %{conn: conn, logs: logs} do
      {:ok, view, _html} = live(conn, ~p"/painel/mensagens")

      assert rows(view) == 25
      assert has_element?(view, "#load-more")

      view |> element("#load-more") |> render_click()

      assert rows(view) == 30
      refute has_element?(view, "#load-more")
      assert Enum.all?(logs, &has_element?(view, "#messages-#{&1.id}"))
    end

    test "changing the filter starts again from the first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/painel/mensagens")
      view |> element("#load-more") |> render_click()

      view |> element("#filter-all") |> render_click()

      assert rows(view) == 25
      assert has_element?(view, "#load-more")
    end

    test "asking for more with nothing more is harmless", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/painel/mensagens")
      view |> element("#load-more") |> render_click()

      assert render_click(view, "more") =~ "Mensagens"
      assert rows(view) == 30
    end
  end
end
