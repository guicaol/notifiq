defmodule Mix.Tasks.Notifiq.CreateAccount do
  @shortdoc "Creates a tenant and its first panel user"

  @moduledoc """
  Creates a tenant and its first user (there is no public sign-up, Spec 010).

      mix notifiq.create_account --tenant "Loja Exemplo" --email dono@loja.com
      mix notifiq.create_account --tenant "Loja Exemplo" --email dono@loja.com --password "uma senha longa" --credits 100

  Without `--password` a random one is generated and printed once; it is not stored
  anywhere in plain text. `--credits` adds that many credits to the new tenant.
  """

  use Mix.Task

  alias Notifiq.Accounts
  alias Notifiq.Mensageria

  @switches [tenant: :string, email: :string, password: :string, credits: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("Unknown or malformed options: #{inspect(invalid)}")

    tenant = opts[:tenant] || Mix.raise("--tenant is required")
    email = opts[:email] || Mix.raise("--email is required")

    Mix.Task.run("app.start")

    {password, generated?} =
      case opts[:password] do
        nil -> {generate_password(), true}
        password -> {password, false}
      end

    case Accounts.create_account(%{tenant_name: tenant, email: email, password: password}) do
      {:ok, %{tenant: tenant, user: user}} ->
        if credits = opts[:credits],
          do: {:ok, _balance} = Mensageria.add_credits(tenant.id, credits)

        Mix.shell().info("Created tenant #{tenant.id} (#{tenant.name}) and user #{user.email}.")

        if generated? do
          Mix.shell().info("Generated password (shown only now): #{password}")
        end

      {:error, changeset} ->
        Mix.raise("Could not create the account: #{format_errors(changeset)}")
    end
  end

  defp generate_password,
    do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%\{(\w+)\}/, message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end
end
