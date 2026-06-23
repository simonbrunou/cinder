defmodule Cinder.AccountsTest do
  use Cinder.DataCase

  alias Cinder.Accounts

  import Cinder.AccountsFixtures
  alias Cinder.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1 (password + auto-confirm)" do
    test "hashes password and auto-confirms" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(%{email: email, password: valid_user_password()})
      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
      refute is_nil(user.confirmed_at)
    end

    test "first user becomes admin, subsequent users are :user" do
      {:ok, first} =
        Accounts.register_user(%{email: unique_user_email(), password: valid_user_password()})

      {:ok, second} =
        Accounts.register_user(%{email: unique_user_email(), password: valid_user_password()})

      assert first.role == :admin
      assert second.role == :user
    end

    test "ignores a role param (no privilege escalation)" do
      {:ok, _admin} =
        Accounts.register_user(%{email: unique_user_email(), password: valid_user_password()})

      {:ok, user} =
        Accounts.register_user(%{
          "email" => unique_user_email(),
          "password" => valid_user_password(),
          "role" => "admin"
        })

      assert user.role == :user
    end

    test "requires a valid password" do
      {:error, changeset} =
        Accounts.register_user(%{email: unique_user_email(), password: "short"})

      assert %{password: _} = errors_on(changeset)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "FK cascade (foreign_keys: :on)" do
    test "deleting a user cascade-deletes their requests" do
      user = user_fixture()

      request =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: user.id,
          target_type: "movie",
          target_id: 555,
          status: :pending
        })

      assert {:ok, _} = Repo.delete(user)
      refute Repo.get(Cinder.Requests.Request, request.id)
    end
  end

  describe "M3 quota + admin helpers" do
    test "request_quota defaults to nil and can be set/cleared" do
      user = user_fixture()
      assert user.request_quota == nil
      assert {:ok, user} = Accounts.update_user_quota(user, 3)
      assert user.request_quota == 3
      assert {:ok, user} = Accounts.update_user_quota(user, nil)
      assert user.request_quota == nil
    end

    test "update_user_quota rejects negatives" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.update_user_quota(user, -1)
      assert "must be greater than or equal to 0" in errors_on(changeset).request_quota
    end

    test "admin_exists? reflects whether any user is present" do
      refute Accounts.admin_exists?()
      _user = user_fixture()
      assert Accounts.admin_exists?()
    end

    test "list_users returns all users ordered by id" do
      a = user_fixture()
      b = user_fixture()
      assert Enum.map(Accounts.list_users(), & &1.id) == [a.id, b.id]
    end
  end

  describe "count_admins/0" do
    test "counts only admins" do
      _user = user_fixture()
      _admin = admin_fixture()
      assert Accounts.count_admins() == 1
    end

    test "is zero when there are no users" do
      assert Accounts.count_admins() == 0
    end
  end

  describe "update_user_role/2" do
    test "promotes a user to admin and audits it" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:ok, %User{role: :admin, id: tid}} =
               Accounts.update_user_role(actor, target, :admin)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^tid)
      assert audit.action == "update_user_role"
      assert audit.entity_type == "User"
      assert audit.actor_id == actor.id
      assert audit.detail["role"] == "admin"
    end

    test "demotes a second admin to user" do
      actor = admin_fixture()
      target = admin_fixture()
      assert {:ok, %User{role: :user}} = Accounts.update_user_role(actor, target, :user)
    end

    test "refuses to demote the last admin and writes no audit row" do
      actor = admin_fixture()

      assert {:error, :last_admin} = Accounts.update_user_role(actor, actor, :user)
      assert Repo.reload!(actor).role == :admin
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end
  end

  describe "create_user/1" do
    test "creates a confirmed user with the default :user role" do
      email = unique_user_email()

      assert {:ok, %User{} = user} =
               Accounts.create_user(%{
                 email: email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert user.email == email
      assert user.role == :user
      assert user.confirmed_at
      assert is_binary(user.hashed_password)
    end

    test "creates an admin when role: :admin is given" do
      assert {:ok, %User{role: :admin}} =
               Accounts.create_user(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 role: :admin
               })
    end

    test "rejects a password confirmation mismatch" do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: "nope nope nope"
               })

      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "rejects a duplicate email" do
      existing = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(%{
                 email: existing.email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
