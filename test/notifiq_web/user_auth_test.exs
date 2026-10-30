defmodule NotifiqWeb.UserAuthTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers, only: [tenant!: 0]

  alias Notifiq.Accounts
  alias Phoenix.LiveView.Socket
  alias NotifiqWeb.UserAuth

  defp socket, do: %Socket{assigns: %{__changed__: %{}, flash: %{}}}

  describe "on_mount(:require_authenticated) (Spec 010, FR-13)" do
    # The router also guards the HTTP request, so this is the second line of defence: a
    # connected mount (websocket) must check the token again on its own.
    test "mounts with the current scope of a valid session" do
      tenant = tenant!()
      user = user!(tenant)
      token = Accounts.generate_user_session_token(user)

      assert {:cont, socket} =
               UserAuth.on_mount(:require_authenticated, %{}, %{"user_token" => token}, socket())

      assert socket.assigns.current_scope.tenant.id == tenant.id
      assert socket.assigns.current_scope.user.id == user.id
    end

    test "halts and redirects to the login when the session was revoked" do
      token = Accounts.generate_user_session_token(user!(tenant!()))
      Accounts.delete_user_session_token(token)

      assert {:halt, socket} =
               UserAuth.on_mount(:require_authenticated, %{}, %{"user_token" => token}, socket())

      assert {:redirect, %{to: "/entrar"}} = socket.redirected
    end

    test "halts without a token, or with a forged one" do
      for session <- [%{}, %{"user_token" => "forged"}, %{"user_token" => nil}] do
        assert {:halt, socket} =
                 UserAuth.on_mount(:require_authenticated, %{}, session, socket())

        assert {:redirect, %{to: "/entrar"}} = socket.redirected
      end
    end
  end

  describe "safe_return_to/1 (Spec 010, FR-11)" do
    test "accepts local paths, with their query" do
      assert UserAuth.safe_return_to("/painel") == "/painel"
      assert UserAuth.safe_return_to("/painel/integracoes?x=1") == "/painel/integracoes?x=1"
    end

    test "refuses anything that could leave the site" do
      for bad <- [
            "//evil.example",
            "/\\evil.example",
            "https://evil.example",
            "http://evil.example/painel",
            "javascript:alert(1)",
            "painel",
            "",
            nil,
            %{},
            123
          ] do
        assert UserAuth.safe_return_to(bad) == nil, inspect(bad)
      end
    end
  end
end
