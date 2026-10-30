defmodule Mix.Tasks.Notifiq.CreateAccountTest do
  use Notifiq.DataCase, async: false

  alias Mix.Tasks.Notifiq.CreateAccount
  alias Notifiq.Accounts
  alias Notifiq.Mensageria

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> message
    after
      0 -> nil
    end
  end

  test "AC-14: creates the tenant and the user with the given password" do
    CreateAccount.run(~w(--tenant Loja_Task --email Dono@Task.com --password uma-senha-bem-longa))

    assert %{tenant_id: tenant_id} =
             Accounts.get_user_by_email_and_password("dono@task.com", "uma-senha-bem-longa")

    assert Notifiq.Tenants.get_tenant(tenant_id).name == "Loja_Task"
    assert Mensageria.credit_balance(tenant_id) == 0
    refute output() =~ "uma-senha-bem-longa"
  end

  test "AC-14: without --password generates one that works, shown once" do
    CreateAccount.run(~w(--tenant Loja_Gerada --email gerada@task.com))

    _created = output()
    shown = output()
    assert shown =~ "Generated password"
    [_, password] = String.split(shown, ": ", parts: 2)

    assert %Notifiq.Accounts.User{} =
             Accounts.get_user_by_email_and_password("gerada@task.com", String.trim(password))
  end

  test "adds the credits asked for" do
    CreateAccount.run(~w(--tenant Loja_Cred --email cred@task.com --credits 25))

    %{tenant_id: tenant_id} = Accounts.get_user_by_email("cred@task.com")
    assert Mensageria.credit_balance(tenant_id) == 25
  end

  test "refuses a missing tenant or email" do
    assert_raise Mix.Error, ~r/--tenant is required/, fn ->
      CreateAccount.run(~w(--email x@task.com))
    end

    assert_raise Mix.Error, ~r/--email is required/, fn ->
      CreateAccount.run(~w(--tenant X))
    end
  end

  test "refuses unknown options" do
    assert_raise Mix.Error, ~r/Unknown or malformed/, fn ->
      CreateAccount.run(~w(--tenant X --email x@task.com --admin))
    end
  end

  test "reports why an account could not be created, and creates nothing" do
    assert_raise Mix.Error, ~r/Could not create the account/, fn ->
      CreateAccount.run(~w(--tenant Loja_Ruim --email ruim@task.com --password curta))
    end

    assert Accounts.get_user_by_email("ruim@task.com") == nil
    assert Notifiq.Repo.get_by(Notifiq.Tenants.Tenant, name: "Loja_Ruim") == nil
  end
end
