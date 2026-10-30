defmodule NotifiqWeb.PageController do
  use NotifiqWeb, :controller

  # There is no public site yet: the entrance is the panel, or the login that guards it.
  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/painel")
    else
      redirect(conn, to: ~p"/entrar")
    end
  end
end
