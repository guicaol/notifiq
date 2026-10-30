defmodule NotifiqWeb.PageController do
  use NotifiqWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
