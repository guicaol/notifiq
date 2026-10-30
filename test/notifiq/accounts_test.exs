defmodule Notifiq.AccountsTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers, only: [tenant!: 0]

  alias Notifiq.Accounts
  alias Notifiq.Accounts.Scope
  alias Notifiq.Accounts.User
  alias Notifiq.Accounts.UserToken
  alias Notifiq.Repo
  alias Notifiq.Tenants
  alias Notifiq.Tenants.Tenant

  defp account_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        tenant_name: "Loja #{System.unique_integer([:positive])}",
        email: "dono#{System.unique_integer([:positive])}@example.com",
        password: password()
      },
      overrides
    )
  end

  defp tenant_count, do: Repo.aggregate(Tenant, :count)

  describe "create_account/1 (AC-1)" do
    test "creates the tenant and its user, with the password hashed" do
      assert {:ok, %{tenant: tenant, user: user}} = Accounts.create_account(account_attrs())

      assert user.tenant_id == tenant.id
      assert user.hashed_password != password()
      refute user.hashed_password =~ password()
      assert String.starts_with?(user.hashed_password, "$pbkdf2")
      assert user.password == nil
    end

    test "stores the email trimmed and lowercased" do
      assert {:ok, %{user: user}} =
               Accounts.create_account(account_attrs(%{email: "  Dono@Loja.COM "}))

      assert user.email == "dono@loja.com"
    end

    test "refuses a duplicate email in any case, and leaves no tenant behind" do
      assert {:ok, _} = Accounts.create_account(account_attrs(%{email: "dup@example.com"}))
      before = tenant_count()

      assert {:error, changeset} =
               Accounts.create_account(account_attrs(%{email: "DUP@example.com"}))

      assert %{email: ["has already been taken"]} = errors_on(changeset)
      assert tenant_count() == before
    end

    test "refuses a malformed email" do
      for email <- ["", "no-at-sign", "a@b@c", "with space@x.com", nil] do
        assert {:error, changeset} = Accounts.create_account(account_attrs(%{email: email}))
        assert Map.has_key?(errors_on(changeset), :email), inspect(email)
      end
    end

    test "refuses a password that is too short, too long or missing" do
      assert {:error, short} = Accounts.create_account(account_attrs(%{password: "short"}))
      assert %{password: [_]} = errors_on(short)

      assert {:error, long} =
               Accounts.create_account(account_attrs(%{password: String.duplicate("a", 129)}))

      assert %{password: [_]} = errors_on(long)

      assert {:error, missing} = Accounts.create_account(account_attrs(%{password: nil}))
      assert %{password: ["can't be blank"]} = errors_on(missing)
    end

    test "an invalid user leaves no tenant behind" do
      before = tenant_count()
      assert {:error, _} = Accounts.create_account(account_attrs(%{password: "short"}))
      assert tenant_count() == before
    end

    test "an invalid tenant name is refused" do
      assert {:error, changeset} = Accounts.create_account(account_attrs(%{tenant_name: ""}))
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "get_user_by_email_and_password/2 (AC-2)" do
    setup do
      %{user: user!(tenant!(), %{email: "ana@example.com"})}
    end

    test "returns the user for the right password", %{user: user} do
      assert %User{id: id} =
               Accounts.get_user_by_email_and_password("ana@example.com", password())

      assert id == user.id
    end

    test "normalizes the email" do
      assert %User{} = Accounts.get_user_by_email_and_password("  ANA@Example.com ", password())
    end

    test "returns nil for a wrong password" do
      assert nil == Accounts.get_user_by_email_and_password("ana@example.com", "wrong password!!")
    end

    test "returns nil for an unknown email" do
      assert nil == Accounts.get_user_by_email_and_password("nobody@example.com", password())
    end

    test "returns nil for values that are not text, without raising" do
      assert nil == Accounts.get_user_by_email_and_password(nil, nil)
      assert nil == Accounts.get_user_by_email_and_password(%{}, ["x"])
      assert nil == Accounts.get_user_by_email_and_password("ana@example.com", nil)
    end

    test "refuses an over-long password without hashing it" do
      assert nil ==
               Accounts.get_user_by_email_and_password(
                 "ana@example.com",
                 String.duplicate("a", 100_000)
               )
    end
  end

  describe "session tokens (AC-3)" do
    setup do
      %{user: user!(tenant!())}
    end

    test "a token gives back its user", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert is_binary(token)
      assert %User{id: id} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "the database keeps only the hash, never the token", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert [stored] = Repo.all(UserToken) |> Enum.filter(&(&1.user_id == user.id))
      refute stored.token == token
      assert stored.token == :crypto.hash(:sha256, token)
    end

    test "two sessions get different tokens", %{user: user} do
      refute Accounts.generate_user_session_token(user) ==
               Accounts.generate_user_session_token(user)
    end

    test "an unknown, empty or non-binary token gives nothing" do
      assert nil == Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32))
      assert nil == Accounts.get_user_by_session_token("")
      assert nil == Accounts.get_user_by_session_token(nil)
    end

    test "the stored hash is not a usable token", %{user: user} do
      Accounts.generate_user_session_token(user)
      [stored] = Repo.all(UserToken) |> Enum.filter(&(&1.user_id == user.id))

      assert nil == Accounts.get_user_by_session_token(stored.token)
    end

    test "deleting the token ends the session", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      other = Accounts.generate_user_session_token(user)

      assert :ok = Accounts.delete_user_session_token(token)

      assert nil == Accounts.get_user_by_session_token(token)
      assert %User{} = Accounts.get_user_by_session_token(other)
    end

    test "a session older than 14 days is refused", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      age_session!(user, 13)
      assert %User{} = Accounts.get_user_by_session_token(token)

      age_session!(user, 15)
      assert nil == Accounts.get_user_by_session_token(token)
    end

    test "reset_password/2 changes the password and revokes every session", %{user: user} do
      token_a = Accounts.generate_user_session_token(user)
      token_b = Accounts.generate_user_session_token(user)
      bystander = user!(tenant!())
      bystander_token = Accounts.generate_user_session_token(bystander)

      assert {:ok, _} = Accounts.reset_password(user, "a brand new password")

      assert nil == Accounts.get_user_by_session_token(token_a)
      assert nil == Accounts.get_user_by_session_token(token_b)
      assert %User{} = Accounts.get_user_by_session_token(bystander_token)

      assert nil == Accounts.get_user_by_email_and_password(user.email, password())
      assert %User{} = Accounts.get_user_by_email_and_password(user.email, "a brand new password")
    end

    test "reset_password/2 with an invalid password changes nothing", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert {:error, changeset} = Accounts.reset_password(user, "short")
      assert %{password: [_]} = errors_on(changeset)

      assert %User{} = Accounts.get_user_by_session_token(token)
      assert %User{} = Accounts.get_user_by_email_and_password(user.email, password())
    end
  end

  describe "the database (AC-4)" do
    test "refuses a user without a tenant" do
      assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
        Repo.insert_all("users", [
          %{
            id: Ecto.UUID.bingenerate(),
            email: "x@example.com",
            hashed_password: "x",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    test "refuses a user whose tenant doesn't exist" do
      changeset =
        User.registration_changeset(%User{tenant_id: Ecto.UUID.generate()}, %{
          email: "x@example.com",
          password: password()
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{tenant_id: [_]} = errors_on(changeset)
    end

    test "refuses an email that isn't lowercase, even when inserted directly" do
      tenant = tenant!()

      assert_raise Postgrex.Error, ~r/email_lowercase/, fn ->
        Repo.insert_all("users", [
          %{
            id: Ecto.UUID.bingenerate(),
            tenant_id: Ecto.UUID.dump!(tenant.id),
            email: "Upper@Example.com",
            hashed_password: "x",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    test "refuses a duplicate email" do
      tenant = tenant!()
      user!(tenant, %{email: "same@example.com"})

      assert_raise Postgrex.Error, ~r/users_email_index/, fn ->
        Repo.insert_all("users", [
          %{
            id: Ecto.UUID.bingenerate(),
            tenant_id: Ecto.UUID.dump!(tenant.id),
            email: "same@example.com",
            hashed_password: "x",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end

    test "the hash and the password never show up when a user is inspected (AC-16)" do
      user = user!(tenant!())
      user = %{user | password: "typed password"}

      shown = inspect(user)

      refute shown =~ "typed password"
      refute shown =~ user.hashed_password
    end
  end

  describe "Scope" do
    test "carries the user's own tenant" do
      tenant = tenant!()
      user = user!(tenant)

      assert %Scope{user: ^user, tenant: %Tenant{id: id}} = Scope.for_user(user)
      assert id == tenant.id
      assert Scope.tenant_id(Scope.for_user(user)) == tenant.id
    end

    test "is nil without a user" do
      assert nil == Scope.for_user(nil)
    end

    test "two users of different tenants never share one" do
      a = user!(tenant!())
      b = user!(tenant!())

      refute Scope.tenant_id(Scope.for_user(a)) == Scope.tenant_id(Scope.for_user(b))
      assert Tenants.get_tenant(a.tenant_id).id == Scope.tenant_id(Scope.for_user(a))
    end
  end
end
