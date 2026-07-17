defmodule Cinder.AccountsTest do
  use Cinder.DataCase

  alias Cinder.Accounts

  import Cinder.AccountsFixtures
  alias Cinder.Accounts.{User, UserToken}

  @bootstrap_token "test-bootstrap-token"

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

  describe "register_user/2 (password + auto-confirm)" do
    test "treats blank configured bootstrap tokens as missing" do
      previous = Application.get_env(:cinder, :bootstrap_token)

      on_exit(fn -> Application.put_env(:cinder, :bootstrap_token, previous) end)

      for token <- ["", " \t\n"] do
        Application.put_env(:cinder, :bootstrap_token, token)

        refute Accounts.valid_bootstrap_token?(token)

        assert {:error, :invalid_bootstrap_token} =
                 Accounts.register_user(
                   %{email: unique_user_email(), password: valid_user_password()},
                   token
                 )
      end
    end

    test "hashes password and auto-confirms" do
      email = unique_user_email()

      {:ok, user} =
        Accounts.register_user(
          %{email: email, password: valid_user_password()},
          @bootstrap_token
        )

      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
      refute is_nil(user.confirmed_at)
    end

    test "first user becomes admin, subsequent users are :user" do
      {:ok, first} =
        Accounts.register_user(
          %{email: unique_user_email(), password: valid_user_password()},
          @bootstrap_token
        )

      {:ok, second} =
        Accounts.register_user(%{email: unique_user_email(), password: valid_user_password()})

      assert first.role == :admin
      assert second.role == :user
    end

    test "ignores a role param (no privilege escalation)" do
      {:ok, _admin} =
        Accounts.register_user(
          %{email: unique_user_email(), password: valid_user_password()},
          @bootstrap_token
        )

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
        Accounts.register_user(
          %{email: unique_user_email(), password: "short"},
          @bootstrap_token
        )

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

  describe "replace_user_session_token/2" do
    test "does not mint a replacement after the old session was revoked" do
      user = user_fixture()
      old_token = Accounts.generate_user_session_token(user)
      assert :ok = Accounts.delete_user_session_token(old_token)

      assert {:error, :session_revoked} =
               Accounts.replace_user_session_token(user, old_token)

      refute Repo.get_by(UserToken, user_id: user.id, context: "session")
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

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
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
      admin = admin_fixture()
      user = user_fixture()
      assert user.request_quota == nil
      assert {:ok, user} = Accounts.update_user_quota(admin, user, 3)
      assert user.request_quota == 3
      assert {:ok, user} = Accounts.update_user_quota(admin, user, nil)
      assert user.request_quota == nil
    end

    test "update_user_quota rejects negatives" do
      admin = admin_fixture()
      user = user_fixture()
      assert {:error, changeset} = Accounts.update_user_quota(admin, user, -1)
      assert "must be greater than or equal to 0" in errors_on(changeset).request_quota
    end

    test "update_user_quota writes an admin_audit row" do
      admin = admin_fixture()
      user = user_fixture()
      assert {:ok, _} = Accounts.update_user_quota(admin, user, 4)

      row = Repo.get_by(Cinder.Audit.AdminAudit, action: "update_user_quota")
      assert row.actor_id == admin.id
      assert row.entity_type == "User"
      assert row.entity_id == user.id
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
      tokens = for _ <- 1..2, do: Accounts.generate_user_session_token(target)

      assert {:ok, %User{role: :admin, id: tid}, revoked_tokens} =
               Accounts.update_user_role(actor, target, :admin)

      assert Enum.map(revoked_tokens, & &1.token) |> Enum.sort() == Enum.sort(tokens)
      Enum.each(tokens, &refute(Accounts.get_user_by_session_token(&1)))

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^tid)
      assert audit.action == "update_user_role"
      assert audit.entity_type == "User"
      assert audit.actor_id == actor.id
      assert audit.detail["role"] == "admin"
    end

    test "demotes a second admin to user" do
      actor = admin_fixture()
      target = admin_fixture()
      assert {:ok, %User{role: :user}, []} = Accounts.update_user_role(actor, target, :user)
    end

    test "refuses to demote the last admin and writes no audit row" do
      actor = admin_fixture()

      assert {:error, :last_admin} = Accounts.update_user_role(actor, actor, :user)
      assert Repo.reload!(actor).role == :admin
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end

    test "rejects an actor whose persisted admin role was revoked" do
      stale_admin = admin_fixture()
      demoter = admin_fixture()
      target = user_fixture()

      {:ok, _} = stale_admin |> Ecto.Changeset.change(role: :user) |> Repo.update()

      assert {:error, :unauthorized} =
               Accounts.update_user_role(stale_admin, target, :admin)

      assert Repo.reload!(target).role == :user
      assert Repo.reload!(demoter).role == :admin
    end
  end

  describe "create_user/1" do
    test "creates a confirmed user with the default :user role" do
      actor = admin_fixture()
      email = unique_user_email()

      assert {:ok, %User{} = user} =
               Accounts.create_user(actor, %{
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
      actor = admin_fixture()

      assert {:ok, %User{role: :admin}} =
               Accounts.create_user(actor, %{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 role: :admin
               })
    end

    test "rejects a password confirmation mismatch" do
      actor = admin_fixture()

      assert {:error, changeset} =
               Accounts.create_user(actor, %{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: "nope nope nope"
               })

      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "rejects a duplicate email" do
      actor = admin_fixture()
      existing = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(actor, %{
                 email: existing.email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "admin_update_email/2" do
    test "changes the email directly and audits it" do
      actor = admin_fixture()
      target = user_fixture()
      new_email = unique_user_email()

      assert {:ok, %User{} = updated} =
               Accounts.admin_update_email(actor, target, %{email: new_email})

      assert updated.email == new_email

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^target.id)
      assert audit.action == "admin_update_email"
      assert audit.detail["email"] == new_email
    end

    test "rejects an invalid email" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:error, changeset} =
               Accounts.admin_update_email(actor, target, %{email: "not an email"})

      assert %{email: _} = errors_on(changeset)
    end

    test "treats an unchanged email as a successful no-op without auditing" do
      actor = admin_fixture()
      target = user_fixture()
      Repo.delete_all(Cinder.Audit.AdminAudit)

      assert {:ok, %User{} = updated} =
               Accounts.admin_update_email(actor, target, %{email: target.email})

      assert updated.email == target.email
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end
  end

  describe "admin_reset_password/2" do
    test "sets a new password, expires the target's sessions, and audits it" do
      actor = admin_fixture()
      target = user_fixture() |> set_password()
      old_token = Accounts.generate_user_session_token(target)

      assert {:ok, %User{} = updated, revoked_tokens} =
               Accounts.admin_reset_password(actor, target, %{
                 password: "brand new password!",
                 password_confirmation: "brand new password!"
               })

      assert Enum.map(revoked_tokens, & &1.token) == [old_token]
      assert Accounts.get_user_by_email_and_password(updated.email, "brand new password!")
      refute Accounts.get_user_by_session_token(old_token)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^target.id)
      assert audit.action == "admin_reset_password"
    end

    test "rejects a too-short password" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:error, changeset} =
               Accounts.admin_reset_password(actor, target, %{
                 password: "short",
                 password_confirmation: "short"
               })

      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
    end
  end

  describe "delete_user/1" do
    test "deletes a user, cascades their requests, and audits it" do
      actor = admin_fixture()
      target = user_fixture()

      req =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: target.id,
          target_id: 603,
          target_type: "movie",
          title: "The Matrix",
          status: :pending
        })

      old_token = Accounts.generate_user_session_token(target)

      assert {:ok, %User{id: tid}, revoked_tokens} = Accounts.delete_user(actor, target)
      assert Enum.map(revoked_tokens, & &1.token) == [old_token]
      refute Repo.get(User, tid)
      refute Repo.get(Cinder.Requests.Request, req.id)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^tid)
      assert audit.action == "delete_user"
      assert audit.entity_type == "User"
      assert audit.detail["email"] == target.email
      assert audit.detail["cascaded_requests"] == true
    end

    test "nilifies approved_by_id on requests the deleted user approved" do
      actor = admin_fixture()
      approver = admin_fixture()
      requester = user_fixture()

      req =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: requester.id,
          approved_by_id: approver.id,
          target_id: 27_205,
          target_type: "movie",
          title: "Inception",
          status: :approved
        })

      assert {:ok, _, _} = Accounts.delete_user(actor, approver)
      assert Repo.get(Cinder.Requests.Request, req.id).approved_by_id == nil
    end

    test "refuses to delete the last admin and writes no audit row" do
      actor = admin_fixture()
      Repo.delete_all(Cinder.Audit.AdminAudit)

      assert {:error, :last_admin} = Accounts.delete_user(actor, actor)
      assert Repo.reload!(actor)
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end

    test "refuses to delete your own account" do
      actor = admin_fixture()
      _second = admin_fixture()
      assert {:error, :self_delete} = Accounts.delete_user(actor, actor)
      assert Repo.reload!(actor)
    end
  end

  describe "login_or_register_plex_user/1" do
    test "matches an existing user by plex_id and logs in" do
      user = user_fixture() |> Ecto.Changeset.change(plex_id: 1001) |> Repo.update!()

      assert {:ok, matched} =
               Accounts.login_or_register_plex_user(%{id: 1001, email: nil, username: "someone"})

      assert matched.id == user.id
    end

    test "refreshes plex_username on a plex_id match if it changed" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(plex_id: 1002, plex_username: "old-name")
        |> Repo.update!()

      assert {:ok, updated} =
               Accounts.login_or_register_plex_user(%{id: 1002, email: nil, username: "new-name"})

      assert updated.id == user.id
      assert updated.plex_username == "new-name"
    end

    test "a second login by plex_id after account creation matches the same user" do
      assert {:ok, created} =
               Accounts.login_or_register_plex_user(%{
                 id: 2001,
                 email: "created-2001@example.com",
                 username: "someone"
               })

      assert {:ok, again} =
               Accounts.login_or_register_plex_user(%{id: 2001, email: nil, username: "someone"})

      assert again.id == created.id
    end

    test "creates a new :user when no plex_id matches, even though another account exists" do
      existing = user_fixture()

      assert {:ok, created} =
               Accounts.login_or_register_plex_user(%{
                 id: 3001,
                 email: "brandnew-3001@example.com",
                 username: "the-newcomer"
               })

      assert created.id != existing.id
      assert created.role == :user
      assert created.plex_id == 3001
      assert Repo.reload!(existing).plex_id == nil
    end

    # SECURITY regression (the exact hole this rework closes): a Plex account whose reported
    # email happens to match an existing admin's, with no plex_id match, must NEVER be resolved
    # to that admin's row — email is not proof of inbox ownership, and the only other gate is
    # "has access to the configured Plex server" (any watch-only friend passes). Because
    # users.email is uniquely indexed, the safe outcome is a rejected create (not a login and not
    # a second row) — the admin row is left completely untouched either way.
    test "an email collision with an existing admin, with no plex_id match, never resolves to that admin" do
      admin = admin_fixture(email: "admin-collision@example.com")
      count_before = Repo.aggregate(User, :count)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.login_or_register_plex_user(%{
                 id: 4444,
                 email: "admin-collision@example.com",
                 username: "attacker"
               })

      reloaded = Repo.reload!(admin)
      assert reloaded.role == :admin
      assert reloaded.plex_id == nil
      assert Repo.aggregate(User, :count) == count_before
    end

    test "{:error, :no_email} for a Plex account with no email and no existing plex_id match" do
      assert {:error, :no_email} =
               Accounts.login_or_register_plex_user(%{id: 4001, email: nil, username: "no-email"})
    end

    test "creates a new :user-role account with no usable password when nothing matches" do
      assert {:ok, created} =
               Accounts.login_or_register_plex_user(%{
                 id: 5001,
                 email: "brandnew@example.com",
                 username: "brand-new"
               })

      assert created.role == :user
      assert created.request_quota == nil
      assert created.plex_id == 5001
      assert created.confirmed_at

      refute Accounts.get_user_by_email_and_password("brandnew@example.com", "password1234")
      refute Accounts.get_user_by_email_and_password("brandnew@example.com", "")
    end
  end

  describe "link_plex_to_user/2" do
    test "sets plex_id/username and preserves role (admin stays admin)" do
      admin = admin_fixture()

      assert {:ok, linked} =
               Accounts.link_plex_to_user(admin, %{
                 id: 7001,
                 email: "x@example.com",
                 username: "me"
               })

      assert linked.role == :admin
      assert linked.plex_id == 7001
      assert linked.plex_username == "me"
    end

    test "returns {:error, changeset} when that plex_id already belongs to another user" do
      _taken = user_fixture() |> Ecto.Changeset.change(plex_id: 7002) |> Repo.update!()
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.link_plex_to_user(user, %{id: 7002, email: nil, username: "someone-else"})

      assert %{plex_id: ["has already been taken"]} = errors_on(changeset)
      refute Repo.reload!(user).plex_id
    end
  end

  describe "unlink_plex_from_user/1" do
    test "clears plex_id and plex_username" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(plex_id: 8001, plex_username: "linked-name")
        |> Repo.update!()

      assert {:ok, unlinked} = Accounts.unlink_plex_from_user(user)
      assert unlinked.plex_id == nil
      assert unlinked.plex_username == nil
    end
  end
end
