defmodule NotifiqWeb.SessionControllerTest do
  use NotifiqWeb.ConnCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers, only: [tenant!: 0]

  alias Notifiq.Accounts

  setup do
    user = user!(tenant!(), %{email: "ana@example.com"})
    %{user: user}
  end

  defp login(conn, email, pass \\ password()) do
    post(conn, ~p"/entrar", %{"user" => %{"email" => email, "password" => pass}})
  end

  describe "GET /entrar" do
    test "shows the login form", %{conn: conn} do
      conn = get(conn, ~p"/entrar")

      html = html_response(conn, 200)
      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#login-form") |> Enum.count() == 1
      assert LazyHTML.query(document, "#login-form input[type=password]") |> Enum.count() == 1
    end

    test "AC-8: sends a signed-in user to the panel", %{conn: conn, user: user} do
      conn = conn |> log_in(user) |> get(~p"/entrar")
      assert redirected_to(conn) == ~p"/painel"
    end
  end

  describe "POST /entrar (AC-5)" do
    test "signs in and goes to the panel", %{conn: conn, user: user} do
      conn = login(conn, "ana@example.com")

      assert redirected_to(conn) == ~p"/painel"
      token = get_session(conn, :user_token)
      assert %{id: id} = Accounts.get_user_by_session_token(token)
      assert id == user.id
      assert get_session(conn, :live_socket_id) =~ "users_sessions:"
    end

    test "the live socket id doesn't carry the token", %{conn: conn} do
      conn = login(conn, "ana@example.com")

      token = get_session(conn, :user_token)
      refute get_session(conn, :live_socket_id) =~ Base.url_encode64(token)
    end

    test "accepts the email in another case, with spaces", %{conn: conn} do
      conn = login(conn, "  ANA@Example.com ")
      assert redirected_to(conn) == ~p"/painel"
    end

    test "a wrong password shows the form with one generic message and no session", %{conn: conn} do
      conn = login(conn, "ana@example.com", "wrong password!!")

      assert html_response(conn, 200) =~ "login-form"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos."
      assert get_session(conn, :user_token) == nil
    end

    test "an unknown email gets the very same answer", %{conn: conn} do
      wrong_password = login(conn, "ana@example.com", "wrong password!!")
      unknown = login(build_conn(), "nobody@example.com", password())

      assert unknown.status == wrong_password.status

      assert Phoenix.Flash.get(unknown.assigns.flash, :error) ==
               Phoenix.Flash.get(wrong_password.assigns.flash, :error)

      assert get_session(unknown, :user_token) == nil
    end

    test "never sends the typed password back", %{conn: conn} do
      conn = login(conn, "ana@example.com", "typed-secret-password")

      refute html_response(conn, 200) =~ "typed-secret-password"
    end

    test "keeps the typed email in the form", %{conn: conn} do
      conn = login(conn, "ana@example.com", "wrong password!!")

      assert html_response(conn, 200) =~ "ana@example.com"
    end

    test "survives missing or malformed params without crashing", %{conn: conn} do
      for params <- [%{}, %{"user" => "x"}, %{"user" => %{"email" => ["a"]}}, %{"user" => %{}}] do
        conn = post(conn, ~p"/entrar", params)
        assert html_response(conn, 200) =~ "login-form"
        assert get_session(conn, :user_token) == nil
      end
    end

    test "starts a new session id on login (no fixation)", %{conn: conn} do
      before_login = conn |> init_test_session(%{"planted" => "value"})

      conn = login(before_login, "ana@example.com")

      assert get_session(conn, "planted") == nil
    end
  end

  describe "return to the page that was asked for (AC-6)" do
    test "the panel without a session goes to the login", %{conn: conn} do
      conn = get(conn, ~p"/painel")
      assert redirected_to(conn) == ~p"/entrar"
    end

    test "after login the user lands where they were going", %{conn: conn} do
      conn = get(conn, ~p"/painel/integracoes")
      assert redirected_to(conn) == ~p"/entrar"

      conn = conn |> recycle() |> login("ana@example.com")
      assert redirected_to(conn) == ~p"/painel/integracoes"
    end

    test "a stored return path that isn't local is ignored" do
      for bad <- ["//evil.example", "/\\evil.example", "https://evil.example", "evil", nil] do
        conn =
          build_conn()
          |> init_test_session(%{"user_return_to" => bad})
          |> login("ana@example.com")

        assert redirected_to(conn) == ~p"/painel", inspect(bad)
      end
    end
  end

  describe "DELETE /sair (AC-7)" do
    test "ends the session on the server and clears the cookie session", %{conn: conn, user: user} do
      conn = log_in(conn, user)
      token = get_session(conn, :user_token)

      conn = delete(conn, ~p"/sair")

      assert redirected_to(conn) == ~p"/entrar"
      assert get_session(conn, :user_token) == nil
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "disconnects the LiveViews of that session", %{conn: conn, user: user} do
      conn = log_in(conn, user)
      token = get_session(conn, :user_token)
      live_socket_id = "users_sessions:" <> Base.url_encode64(:crypto.hash(:sha256, token))

      conn = conn |> put_session(:live_socket_id, live_socket_id)
      NotifiqWeb.Endpoint.subscribe(live_socket_id)

      delete(conn, ~p"/sair")

      assert_receive %Phoenix.Socket.Broadcast{topic: ^live_socket_id, event: "disconnect"}
    end

    test "the old cookie no longer opens the panel", %{conn: conn, user: user} do
      signed_in = log_in(conn, user)
      old_session = Plug.Conn.get_session(signed_in)

      delete(signed_in, ~p"/sair")

      replay = build_conn() |> init_test_session(old_session) |> get(~p"/painel")
      assert redirected_to(replay) == ~p"/entrar"
    end

    test "signing out without a session is harmless", %{conn: conn} do
      conn = delete(conn, ~p"/sair")
      assert redirected_to(conn) == ~p"/entrar"
    end
  end

  describe "GET / (AC-8)" do
    test "goes to the login without a session", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == ~p"/entrar"
    end

    test "goes to the panel with one", %{conn: conn, user: user} do
      assert conn |> log_in(user) |> get(~p"/") |> redirected_to() == ~p"/painel"
    end
  end
end
