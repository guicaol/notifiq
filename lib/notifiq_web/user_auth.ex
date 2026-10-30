defmodule NotifiqWeb.UserAuth do
  @moduledoc """
  Session handling for the panel (Spec 010): plugs for the controller pipeline and
  `on_mount` hooks for LiveView.

  The tenant of everything that happens behind these plugs is `current_scope.tenant`,
  rebuilt from the session token on every request and on every LiveView mount. Nothing
  the browser sends names a tenant.
  """

  use NotifiqWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Notifiq.Accounts
  alias Notifiq.Accounts.Scope
  alias Notifiq.Accounts.User

  @token_key :user_token
  @return_to_key :user_return_to

  # --- controller side -------------------------------------------------------------

  @doc "Starts a session for `user` and sends them where they were going (or to the panel)."
  def log_in_user(conn, %User{} = user) do
    token = Accounts.generate_user_session_token(user)
    return_to = conn |> get_session(@return_to_key) |> safe_return_to()

    conn
    |> renew_session()
    |> put_session(@token_key, token)
    |> put_session(:live_socket_id, live_socket_id(token))
    |> redirect(to: return_to || ~p"/painel")
  end

  @doc "Ends the session on the server, disconnects its LiveViews and clears the cookie."
  def log_out_user(conn) do
    token = get_session(conn, @token_key)

    if token do
      Accounts.delete_user_session_token(token)
      NotifiqWeb.Endpoint.broadcast(live_socket_id(token), "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/entrar")
  end

  @doc "Plug: assigns `current_scope` (or `nil`) from the session token."
  def fetch_current_scope(conn, _opts) do
    scope =
      conn
      |> get_session(@token_key)
      |> Accounts.get_user_by_session_token()
      |> Scope.for_user()

    assign(conn, :current_scope, scope)
  end

  @doc "Plug: sends visitors without a session to the login page."
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> put_flash(:error, "Entre para continuar.")
      |> redirect(to: ~p"/entrar")
      |> halt()
    end
  end

  @doc "Plug: sends people who are already signed in to the panel."
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
      |> redirect(to: ~p"/painel")
      |> halt()
    else
      conn
    end
  end

  # --- LiveView side ------------------------------------------------------------------

  @doc """
  `:require_authenticated` revalidates the session token on every connected mount, so a
  revoked session never gets a screen.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Entre para continuar.")
        |> Phoenix.LiveView.redirect(to: ~p"/entrar")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      session
      |> Map.get(Atom.to_string(@token_key))
      |> Accounts.get_user_by_session_token()
      |> Scope.for_user()
    end)
  end

  # --- helpers ---------------------------------------------------------------------

  @doc """
  The path to go back to after login, only if it is a local one: it must start with a
  single `/`, so `//evil.example`, `/\\evil.example` and `https://evil.example` are ignored.
  """
  @spec safe_return_to(term()) :: String.t() | nil
  def safe_return_to("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: nil, else: path
  end

  def safe_return_to(_other), do: nil

  # The socket id is derived from the token's hash, so the topic never carries the token.
  defp live_socket_id(token),
    do: "users_sessions:" <> Base.url_encode64(:crypto.hash(:sha256, token))

  # A new session id on every login and logout keeps a pre-login session id from
  # surviving into the authenticated one (session fixation).
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, @return_to_key, current_path(conn))

  defp maybe_store_return_to(conn), do: conn
end
