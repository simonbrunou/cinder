defmodule Cinder.AccountsTest do
  use Cinder.DataCase

  alias Cinder.{Accounts, Settings}

  import Cinder.AccountsFixtures
  alias Cinder.Accounts.{User, UserToken}

  @bootstrap_token "test-bootstrap-token"

  setup do
    default_request_quota = Application.get_env(:cinder, :default_request_quota)

    on_exit(fn ->
      Application.put_env(:cinder, :default_request_quota, default_request_quota)
    end)

    :ok
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
      assert user.active
      assert user.request_quota == nil
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
      assert first.active
      assert second.role == :user
      refute second.active
      assert second.request_quota == 10
    end

    test "uses the configured default quota only for self-registered users" do
      Settings.put("default_request_quota", "4")

      {:ok, admin} =
        Accounts.register_user(
          %{email: unique_user_email(), password: valid_user_password()},
          @bootstrap_token
        )

      {:ok, user} =
        Accounts.register_user(%{email: unique_user_email(), password: valid_user_password()})

      assert admin.request_quota == nil
      assert user.request_quota == 4
    end

    test "an unusable configured quota degrades to unlimited" do
      {:ok, _admin} =
        Accounts.register_user(
          %{email: unique_user_email(), password: valid_user_password()},
          @bootstrap_token
        )

      for value <- ["", "bad", "0", "-1"] do
        Settings.put("default_request_quota", value)

        assert {:ok, %{request_quota: nil}} =
                 Accounts.register_user(%{
                   email: unique_user_email(),
                   password: valid_user_password()
                 })
      end
    end

    test "a signup that lands inactive notifies, so the admin knows someone is waiting" do
      Cinder.TestNotifier.subscribe()

      {:ok, _admin} =
        Accounts.register_user(
          %{email: unique_user_email(), password: valid_user_password()},
          @bootstrap_token
        )

      # The bootstrap admin is active immediately, so there is nobody to tell.
      refute_receive {:notify, {:user_registered, _}}

      email = unique_user_email()
      {:ok, _} = Accounts.register_user(%{email: email, password: valid_user_password()})

      assert_receive {:notify, {:user_registered, %{email: ^email, active: false}}}
    end

    test "a Plex :user row with zero admins does not block bootstrap admin creation" do
      plex_user =
        user_fixture()
        |> Ecto.Changeset.change(plex_id: 1234)
        |> Repo.update!()

      assert Accounts.count_admins() == 0

      assert {:ok, admin} =
               Accounts.register_user(
                 %{email: unique_user_email(), password: valid_user_password()},
                 @bootstrap_token
               )

      assert admin.role == :admin
      assert admin.active
      assert Repo.reload!(plex_user).role == :user
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
    test "validates the authenticated_at time against the shared 10-minute default window" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -9, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -11, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -6, :minute)},
               -5
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

  describe "user locale" do
    test "accepts supported locales and rejects unsupported values" do
      user = user_fixture()

      assert {:ok, %{locale: "fr"}} = Accounts.update_user_locale(user, %{locale: "fr"})

      assert {:error, changeset} =
               Accounts.update_user_locale(user, %{locale: "not-supported"})

      assert "is invalid" in errors_on(changeset).locale
    end
  end

  describe "user notify_email" do
    test "defaults to true and can be toggled" do
      user = user_fixture()
      assert user.notify_email == true

      assert {:ok, %{notify_email: false}} =
               Accounts.update_user_notify_email(user, %{notify_email: false})

      assert {:ok, %{notify_email: true}} =
               Accounts.update_user_notify_email(user, %{notify_email: true})
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

  describe "pending account moderation" do
    test "activate_user/2 activates and audits a pending account" do
      actor = admin_fixture()
      pending = user_fixture() |> Ecto.Changeset.change(active: false) |> Repo.update!()

      assert {:ok, %User{active: true}} = Accounts.activate_user(actor, pending)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^pending.id)
      assert audit.action == "activate_user"
      assert audit.detail["active"] == true
    end

    test "activate_user/2 emits an :account_activated notifier event post-commit" do
      Cinder.TestNotifier.subscribe()
      actor = admin_fixture()
      pending = user_fixture() |> Ecto.Changeset.change(active: false) |> Repo.update!()

      assert {:ok, %User{id: id, active: true}} = Accounts.activate_user(actor, pending)
      assert_receive {:notify, {:account_activated, %User{id: ^id}}}
    end

    test "delete_pending_user/2 deletes through the audited user-deletion path" do
      actor = admin_fixture()
      pending = user_fixture() |> Ecto.Changeset.change(active: false) |> Repo.update!()

      assert {:ok, %User{id: id}, []} = Accounts.delete_pending_user(actor, pending)
      refute Repo.get(User, id)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^pending.id)
      assert audit.action == "delete_user"
    end

    test "pending moderation refuses an active account" do
      actor = admin_fixture()
      user = user_fixture()

      assert {:error, :not_pending} = Accounts.activate_user(actor, user)
      assert {:error, :not_pending} = Accounts.delete_pending_user(actor, user)
      assert Repo.reload!(user)
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
      assert user.active
      assert is_binary(user.hashed_password)
      assert user.request_quota == nil
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
      # GDPR Art.17: the new address is never written into the audit detail.
      refute Map.has_key?(audit.detail, "email")
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
      # GDPR Art.17: the erased address is never written into the audit detail.
      refute Map.has_key?(audit.detail, "email")
      assert audit.detail["cascaded_requests"] == true
    end

    # The FK cascade removes the user's requests without per-request events; the pending nav
    # badge and approval queue re-read on this announce — regression for the stale-badge bug.
    test "announces on the requests topic so the pending badge re-reads" do
      actor = admin_fixture()
      target = user_fixture()

      Repo.insert!(%Cinder.Requests.Request{
        user_id: target.id,
        target_id: 603,
        target_type: "movie",
        title: "The Matrix",
        status: :pending
      })

      Cinder.Requests.subscribe()
      assert {:ok, _, _} = Accounts.delete_user(actor, target)
      assert_receive {:request_deleted, nil}
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

    test "scrubs the email out of historical audit rows for the deleted user, keeping other keys" do
      admin = admin_fixture()
      target = user_fixture()

      historical =
        Repo.insert!(%Cinder.Audit.AdminAudit{
          actor_id: admin.id,
          action: "admin_update_email",
          entity_type: "User",
          entity_id: target.id,
          detail: %{"email" => "old@example.com", "role" => "user"}
        })

      assert {:ok, _, _} = Accounts.delete_user(admin, target)

      scrubbed = Repo.get!(Cinder.Audit.AdminAudit, historical.id)
      # The row survives (append-only accountability); only the email value is redacted.
      refute Map.has_key?(scrubbed.detail, "email")
      assert scrubbed.detail["role"] == "user"
    end
  end

  describe "delete_own_account/2" do
    test "deletes the caller's own account with the correct password and revokes their tokens" do
      _admin = admin_fixture()
      user = user_fixture() |> set_password()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, %User{id: id}, revoked_tokens} =
               Accounts.delete_own_account(user, valid_user_password())

      assert Enum.map(revoked_tokens, & &1.token) == [token]
      refute Repo.get(User, id)
      refute Repo.get_by(UserToken, user_id: id)
    end

    test "records a delete_own_account audit row with a nil actor" do
      _admin = admin_fixture()
      user = user_fixture() |> set_password()

      assert {:ok, %User{id: id}, _} = Accounts.delete_own_account(user, valid_user_password())

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^id)
      assert audit.action == "delete_own_account"
      assert audit.entity_type == "User"
      assert audit.actor_id == nil
      refute Map.has_key?(audit.detail, "email")
    end

    test "a wrong password does not delete the account" do
      _admin = admin_fixture()
      user = user_fixture() |> set_password()

      assert {:error, :invalid_password} =
               Accounts.delete_own_account(user, "definitely-not-it!!")

      assert Repo.reload!(user)
    end

    test "the last admin cannot self-delete even with the correct password" do
      admin = admin_fixture() |> set_password()

      assert {:error, :last_admin} = Accounts.delete_own_account(admin, valid_user_password())
      assert Repo.reload!(admin)
    end
  end

  describe "export_user_data/1" do
    test "returns account fields and never the hashed_password or password" do
      user = user_fixture() |> set_password()

      data = Accounts.export_user_data(user)

      assert data.id == user.id
      assert data.email == user.email
      assert data.role == :user
      refute Map.has_key?(data, :hashed_password)
      refute Map.has_key?(data, :password)
    end
  end

  describe "login_or_register_plex_user/1" do
    test "matches an existing user by plex_id and logs in" do
      user = user_fixture() |> Ecto.Changeset.change(plex_id: 1001) |> Repo.update!()

      assert {:ok, matched} =
               Accounts.login_or_register_plex_user(%{id: 1001, email: nil, username: "someone"})

      assert matched.id == user.id
    end

    # A malformed plex.tv response with no integer id must fail closed, not fall through to
    # Repo.get_by(User, plex_id: nil) (= `WHERE plex_id IS NULL`), which would match an
    # arbitrary password-only user or raise MultipleResultsError.
    test "rejects an account with a nil id without matching a null-plex_id user" do
      existing = user_fixture()

      assert {:error, :invalid_account} =
               Accounts.login_or_register_plex_user(%{
                 id: nil,
                 email: "x@example.com",
                 username: "x"
               })

      assert Repo.reload!(existing).plex_username == nil
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
      _admin = admin_fixture()

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
      existing = admin_fixture()

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

    test "refuses to create a new Plex user while no admin exists" do
      assert {:error, :admin_required} =
               Accounts.login_or_register_plex_user(%{
                 id: 3002,
                 email: "blocked-3002@example.com",
                 username: "the-newcomer"
               })

      assert Repo.aggregate(User, :count) == 0
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
      _admin = admin_fixture()

      assert {:ok, created} =
               Accounts.login_or_register_plex_user(%{
                 id: 5001,
                 email: "brandnew@example.com",
                 username: "brand-new"
               })

      assert created.role == :user
      refute created.active
      assert created.request_quota == 10
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

  describe "import_media_server_users/2" do
    defp plex_entry(id, email, username \\ nil) do
      %{id: id, email: email, username: username || "user#{id}"}
    end

    test "creates one passwordless, Plex-linked :user account per entry" do
      actor = admin_fixture()
      email = unique_user_email()

      assert {:ok, [%User{} = imported]} =
               Accounts.import_media_server_users(actor, [plex_entry(4001, email, "kim")])

      assert imported.email == email
      assert imported.role == :user
      assert imported.confirmed_at
      assert imported.active
      assert imported.plex_id == 4001
      assert imported.plex_username == "kim"
      # No password at all: the account is only reachable through the media-server sign-in
      # path (which resolves on plex_id) or an admin password reset.
      assert imported.hashed_password == nil
      refute Accounts.get_user_by_email_and_password(email, valid_user_password())
    end

    test "never creates an admin, even alongside an admin-shaped entry" do
      actor = admin_fixture()

      assert {:ok, imported} =
               Accounts.import_media_server_users(actor, [
                 Map.put(plex_entry(4010, unique_user_email()), :role, :admin)
               ])

      assert Enum.all?(imported, &(&1.role == :user))
    end

    test "re-running the import creates nothing new" do
      actor = admin_fixture()
      entries = [plex_entry(4002, unique_user_email()), plex_entry(4003, unique_user_email())]

      assert {:ok, [_, _]} = Accounts.import_media_server_users(actor, entries)
      before = Repo.aggregate(User, :count)

      assert {:ok, []} = Accounts.import_media_server_users(actor, entries)
      assert Repo.aggregate(User, :count) == before
    end

    test "skips an entry whose email already belongs to a still-pending account" do
      actor = admin_fixture()

      pending =
        user_fixture() |> Ecto.Changeset.change(active: false) |> Repo.update!()

      assert {:ok, []} =
               Accounts.import_media_server_users(actor, [plex_entry(4004, pending.email)])

      # Not resurrected: the pending account keeps its own state and stays unlinked.
      reloaded = Repo.reload!(pending)
      refute reloaded.active
      refute reloaded.plex_id
    end

    test "skips an entry whose plex_id is already linked under a different email" do
      actor = admin_fixture()

      _linked =
        user_fixture() |> Ecto.Changeset.change(plex_id: 4005) |> Repo.update!()

      assert {:ok, []} =
               Accounts.import_media_server_users(actor, [
                 plex_entry(4005, unique_user_email())
               ])
    end

    test "skips a duplicate email inside one payload" do
      actor = admin_fixture()
      email = unique_user_email()

      assert {:ok, [imported]} =
               Accounts.import_media_server_users(actor, [
                 plex_entry(4006, email),
                 plex_entry(4007, email)
               ])

      assert imported.plex_id == 4006
    end

    test "skips an entry the media server reports without an email" do
      actor = admin_fixture()

      assert {:ok, []} =
               Accounts.import_media_server_users(actor, [plex_entry(4008, nil, "no-email")])
    end

    test "imports a Jellyfin-shaped (string id) entry without linking Plex" do
      actor = admin_fixture()
      email = unique_user_email()

      assert {:ok, [imported]} =
               Accounts.import_media_server_users(actor, [
                 %{id: "b7a1-guid", email: email, username: email}
               ])

      assert imported.email == email
      assert imported.plex_id == nil
      assert imported.plex_username == nil
    end

    test "audits every created account" do
      actor = admin_fixture()
      Repo.delete_all(Cinder.Audit.AdminAudit)

      assert {:ok, [imported]} =
               Accounts.import_media_server_users(actor, [
                 plex_entry(4009, unique_user_email())
               ])

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^imported.id)
      assert audit.action == "import_media_server_user"
      assert audit.entity_type == "User"
      assert audit.actor_id == actor.id
      refute Map.has_key?(audit.detail, "email")
    end

    test "refuses a non-admin actor and writes nothing" do
      actor = user_fixture()
      before = Repo.aggregate(User, :count)

      assert {:error, :unauthorized} =
               Accounts.import_media_server_users(actor, [
                 plex_entry(4011, unique_user_email())
               ])

      assert Repo.aggregate(User, :count) == before
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

  describe "login_or_register_jellyfin_user/1" do
    test "matches an existing user by jellyfin_user_id and logs in" do
      user =
        user_fixture() |> Ecto.Changeset.change(jellyfin_user_id: "jf-1001") |> Repo.update!()

      assert {:ok, matched} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-1001", name: "someone"})

      assert matched.id == user.id
    end

    # A malformed response with no id must fail closed, not fall through to
    # Repo.get_by(User, jellyfin_user_id: nil) (= `WHERE jellyfin_user_id IS NULL`), which would
    # match an arbitrary password-only user or raise MultipleResultsError.
    test "rejects an account with a nil id without matching a null-jellyfin_user_id user" do
      existing = user_fixture()

      assert {:error, :invalid_account} =
               Accounts.login_or_register_jellyfin_user(%{id: nil, name: "x"})

      assert Repo.reload!(existing).jellyfin_username == nil
    end

    test "refreshes jellyfin_username on an id match if it changed" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(jellyfin_user_id: "jf-1002", jellyfin_username: "old-name")
        |> Repo.update!()

      assert {:ok, updated} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-1002", name: "new-name"})

      assert updated.id == user.id
      assert updated.jellyfin_username == "new-name"
    end

    test "creates a new pending :user with a synthetic address and no usable password" do
      _admin = admin_fixture()

      assert {:ok, created} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-2001", name: "Brand.New"})

      assert created.role == :user
      refute created.active
      refute created.notify_email
      assert created.request_quota == 10
      assert created.confirmed_at
      assert created.jellyfin_user_id == "jf-2001"
      assert created.email =~ ~r/^brand\.new-[a-z2-7]{10}@jellyfin\.invalid$/

      refute Accounts.get_user_by_email_and_password(created.email, "password1234")
      refute Accounts.get_user_by_email_and_password(created.email, "")
    end

    test "drops the readable prefix when the Jellyfin name sanitizes away" do
      _admin = admin_fixture()

      assert {:ok, created} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-2002", name: "王"})

      assert created.email =~ ~r/^jellyfin-[a-z2-7]{10}@jellyfin\.invalid$/
    end

    # SECURITY: the synthetic address must not be derivable from anything an attacker can see.
    # Two accounts sharing a display name must not collide with each other either.
    test "the synthetic address is randomized, so identical display names never collide" do
      _admin = admin_fixture()

      assert {:ok, first} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-2003", name: "alice"})

      assert {:ok, second} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-2004", name: "Alice"})

      assert first.email != second.email
      assert first.email =~ ~r/^alice-[a-z2-7]{10}@jellyfin\.invalid$/
      assert second.email =~ ~r/^alice-[a-z2-7]{10}@jellyfin\.invalid$/
    end

    test "refuses to create a new Jellyfin user while no admin exists" do
      assert {:error, :admin_required} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-3002", name: "the-newcomer"})

      assert Repo.aggregate(User, :count) == 0
    end

    # SECURITY: the first Jellyfin login always creates a NEW regular user. Cinder never looks an
    # existing account up by email here — an identity the media server vouches for is not proof
    # of inbox ownership, so matching on email would be an account-takeover path. An account
    # already holding the name-derived address must neither be resolved to nor block the create:
    # self-registration is open, so a squatter could otherwise deny a Jellyfin user onboarding.
    test "an account squatting the name-derived address neither logs in nor blocks the create" do
      admin = admin_fixture(email: "attacker@jellyfin.invalid")

      assert {:ok, created} =
               Accounts.login_or_register_jellyfin_user(%{id: "jf-4444", name: "attacker"})

      assert created.id != admin.id
      assert created.role == :user
      assert created.email != admin.email

      reloaded = Repo.reload!(admin)
      assert reloaded.role == :admin
      assert reloaded.jellyfin_user_id == nil
    end
  end

  describe "link_jellyfin_to_user/2" do
    test "sets jellyfin_user_id/username and preserves role (admin stays admin)" do
      admin = admin_fixture()

      assert {:ok, linked} = Accounts.link_jellyfin_to_user(admin, %{id: "jf-7001", name: "me"})

      assert linked.role == :admin
      assert linked.jellyfin_user_id == "jf-7001"
      assert linked.jellyfin_username == "me"
    end

    test "returns {:error, changeset} when that identity already belongs to another user" do
      _taken =
        user_fixture() |> Ecto.Changeset.change(jellyfin_user_id: "jf-7002") |> Repo.update!()

      user = user_fixture()

      assert {:error, changeset} =
               Accounts.link_jellyfin_to_user(user, %{id: "jf-7002", name: "someone-else"})

      assert %{jellyfin_user_id: ["has already been taken"]} = errors_on(changeset)
      refute Repo.reload!(user).jellyfin_user_id
    end
  end

  describe "unlink_jellyfin_from_user/1" do
    test "clears jellyfin_user_id and jellyfin_username" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(jellyfin_user_id: "jf-8001", jellyfin_username: "linked-name")
        |> Repo.update!()

      assert {:ok, unlinked} = Accounts.unlink_jellyfin_from_user(user)
      assert unlinked.jellyfin_user_id == nil
      assert unlinked.jellyfin_username == nil
    end
  end
end
