defmodule NotifiqWeb.PainelLive.DashboardTest do
  use NotifiqWeb.ConnCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Accounts
  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria

  defp signed_in(conn, tenant) do
    user = user!(tenant)
    {log_in(conn, user), user}
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp receipt,
    do: %SendReceipt{provider: "fake_sms", provider_message_id: "SM1", status: :queued}

  describe "access" do
    test "AC-6: needs a session", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel")
    end

    test "AC-12: a revoked session can't mount the LiveView", %{conn: conn} do
      tenant = tenant!()
      {conn, user} = signed_in(conn, tenant)
      token = Plug.Conn.get_session(conn, :user_token)

      assert {:ok, _view, _html} = live(conn, ~p"/painel")

      Accounts.delete_user_session_token(token)

      assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel")
      assert user.tenant_id == tenant.id
    end

    test "an expired session can't mount it either", %{conn: conn} do
      tenant = tenant!()
      {conn, user} = signed_in(conn, tenant)

      age_session!(user, 15)

      assert {:error, {:redirect, %{to: "/entrar"}}} = live(conn, ~p"/painel")
    end
  end

  describe "layout (FR-18)" do
    test "shows the tenant, the user and the way out", %{conn: conn} do
      tenant = tenant!()
      {conn, user} = signed_in(conn, tenant)

      {:ok, view, _html} = live(conn, ~p"/painel")

      assert text(view, "#tenant-name") == tenant.name
      assert text(view, "#user-email") == user.email
      assert has_element?(view, "#logout-link[href='/sair']")
      assert has_element?(view, "#nav-resumo[aria-current=page]")
      assert has_element?(view, "#nav-integracoes")
    end
  end

  describe "summary (AC-9)" do
    test "shows the balance, the counts and the recent messages of the tenant", %{conn: conn} do
      tenant = tenant!(1_234)
      other = tenant!(777)

      sent = reserve!(tenant, %{recipient: "+5511999998888"})
      {:ok, _} = Mensageria.record_outcome(sent, {:ok, receipt()})

      _others = reserve!(other)

      {conn, _user} = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel")

      assert text(view, "#stat-balance") =~ "1.233"
      refute render(view) =~ "777"
      assert text(view, "#stat-sent") =~ "1"
      assert has_element?(view, "#attention-empty")
      assert render(view) =~ "+55 ••••• 8888"
      refute render(view) =~ "5511999998888"
    end

    test "never shows another tenant's balance, counts, numbers or messages", %{conn: conn} do
      mine = tenant!(10)
      theirs = tenant!(98_765)

      theirs_reserved = reserve!(theirs, %{recipient: "+5521988887777"})
      {:ok, _} = Mensageria.record_outcome(theirs_reserved, {:ok, receipt()})

      event = event!(theirs, "bad")
      :ok = Mensageria.update_event_status(theirs.id, event.id, "insufficient_credits")

      {conn, _user} = signed_in(conn, mine)
      {:ok, view, html} = live(conn, ~p"/painel")

      assert text(view, "#stat-balance") =~ "10"
      refute html =~ "98.765"
      refute html =~ "8887777"
      refute html =~ "Sem créditos"
      assert text(view, "#stat-sent") =~ "0"
      assert has_element?(view, "#messages-empty")
    end

    test "events that did not turn into a message are listed with their count", %{conn: conn} do
      tenant = tenant!()

      for {status, n} <- [{"insufficient_credits", 2}, {"render_failed", 1}], i <- 1..n do
        event = event!(tenant, "#{status}-#{i}")
        :ok = Mensageria.update_event_status(tenant.id, event.id, status)
      end

      {conn, _user} = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel")

      refute has_element?(view, "#attention-empty")
      assert text(view, "#problem-insufficient_credits") =~ "2"
      assert text(view, "#problem-render_failed") =~ "1"
      refute has_element?(view, "#problem-invalid_request")
      refute has_element?(view, "#problem-skipped_no_template")
    end

    test "counts only the last 30 days", %{conn: conn} do
      tenant = tenant!()
      event = event!(tenant, "old")
      :ok = Mensageria.update_event_status(tenant.id, event.id, "render_failed")

      import Ecto.Query

      Notifiq.Repo.update_all(
        from(e in Notifiq.Mensageria.WebhookEvent, where: e.tenant_id == ^tenant.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
      )

      {conn, _user} = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel")

      assert has_element?(view, "#attention-empty")
    end

    test "a tenant with no activity gets zeros and empty states, not an error", %{conn: conn} do
      tenant = tenant!()
      {conn, _user} = signed_in(conn, tenant)

      {:ok, view, _html} = live(conn, ~p"/painel")

      assert text(view, "#stat-balance") =~ "0"
      assert text(view, "#stat-failed") =~ "0"
      assert has_element?(view, "#messages-empty")
      assert has_element?(view, "#attention-empty")
    end

    test "failed and unconfirmed messages count as problems, pending as in progress", %{
      conn: conn
    } do
      tenant = tenant!(10)

      failed = reserve!(tenant)
      {:ok, _} = Mensageria.record_outcome(failed, {:error, {:permanent, :invalid_number}})
      _pending = reserve!(tenant)

      {conn, _user} = signed_in(conn, tenant)
      {:ok, view, _html} = live(conn, ~p"/painel")

      assert text(view, "#stat-failed") =~ "1"
      assert text(view, "#stat-in-progress") =~ "1"
    end
  end
end
