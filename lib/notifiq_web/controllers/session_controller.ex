defmodule NotifiqWeb.SessionController do
  use NotifiqWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias Notifiq.Accounts
  alias Notifiq.Accounts.User
  alias NotifiqWeb.UserAuth

  # Same text whether the email is unknown or the password is wrong (Spec 010, FR-10).
  @invalid_credentials "E-mail ou senha inválidos."

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Entrar")
    |> render(:new, form: login_form(""))
  end

  def create(conn, params) do
    user_params = if is_map(params["user"]), do: params["user"], else: %{}
    email = user_params["email"]

    case Accounts.get_user_by_email_and_password(email, user_params["password"]) do
      %User{} = user ->
        conn
        |> put_flash(:info, "Bem-vindo de volta.")
        |> UserAuth.log_in_user(user)

      nil ->
        conn
        |> put_flash(:error, @invalid_credentials)
        |> assign(:page_title, "Entrar")
        |> render(:new, form: login_form(email))
    end
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> put_flash(:info, "Você saiu.")
  end

  # Only the email is sent back to the form, and only a short text one.
  defp login_form(email) when is_binary(email),
    do: to_form(%{"email" => String.slice(email, 0, 160)}, as: :user)

  defp login_form(_email), do: to_form(%{"email" => ""}, as: :user)
end
