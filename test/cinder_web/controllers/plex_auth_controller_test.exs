defmodule CinderWeb.PlexAuthControllerTest do
  use CinderWeb.ConnCase

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Accounts.PlexAuthMock
  alias Cinder.Accounts.User
  alias Cinder.Repo

  setup :verify_on_exit!

  # config/test.exs: the Plex media server's token, owned by the account with plex.tv id 1.
  @owner_token "test-key"
  @owner_id 1

  # The gate after the signing-in account: the owner's account, then the server's share list,
  # both read with the owner's token. Mox runs `account/2` expectations in order, so this goes
  # after the signing-in account's.
  defp expect_owner do
    expect(PlexAuthMock, :account, fn @owner_token, [] ->
      {:ok, %{id: @owner_id, email: "owner@example.com", username: "owner"}}
    end)
  end

  defp expect_shared(share_ids) do
    expect_owner()
    expect(PlexAuthMock, :server_machine_id, fn [] -> {:ok, "machine-1"} end)

    expect(PlexAuthMock, :server_share_ids, fn @owner_token, "machine-1", [] ->
      {:ok, share_ids}
    end)
  end

  describe "GET /auth/plex" do
    test "puts the pin id in the session and redirects to app.plex.tv", %{conn: conn} do
      expect(Cinder.Accounts.PlexAuthMock, :create_pin, fn ->
        {:ok, %{id: 99, code: "WXYZ"}}
      end)

      conn = get(conn, ~p"/auth/plex")

      assert get_session(conn, :plex_pin_id) == 99
      location = redirected_to(conn, 302)
      assert location =~ "https://app.plex.tv/auth#?"
      assert location =~ "clientID="
      assert location =~ "code=WXYZ"
      assert location =~ URI.encode_www_form(url(~p"/auth/plex/callback"))
    end

    test "while logged in, stores :plex_intent => :link and redirects to plex.tv", %{conn: conn} do
      expect(Cinder.Accounts.PlexAuthMock, :create_pin, fn ->
        {:ok, %{id: 100, code: "LINK"}}
      end)

      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/auth/plex")

      assert get_session(conn, :plex_pin_id) == 100
      assert get_session(conn, :plex_intent) == :link
      assert redirected_to(conn, 302) =~ "https://app.plex.tv/auth#?"
    end

    test "not configured while logged in redirects to /users/settings with an error", %{
      conn: conn
    } do
      previous = Application.get_env(:cinder, Cinder.Library.MediaServer.Plex)
      Application.put_env(:cinder, Cinder.Library.MediaServer.Plex, url: nil, token: nil)
      on_exit(fn -> Application.put_env(:cinder, Cinder.Library.MediaServer.Plex, previous) end)

      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/auth/plex")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "SECURITY: logged in but not sudo-fresh redirects to /users/settings without creating a pin",
         %{conn: conn} do
      # verify_on_exit! (setup) with no `expect(create_pin, ...)` set means any call to
      # create_pin/0 is an unexpected Mox call and fails the test.
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        )
        |> get(~p"/auth/plex")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "re-enter your password"

      refute get_session(conn, :plex_pin_id)
    end
  end

  describe "GET /auth/plex/callback" do
    test "happy path ends logged in and redirected", %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 99 -> {:ok, "plex-auth-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "plex-auth-token", [] ->
        {:ok, %{id: 555, email: "newplex@example.com", username: "newplex"}}
      end)

      expect_shared([555])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 99)
        |> get(~p"/auth/plex/callback")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert %{active: false} = user = Repo.get_by(User, email: "newplex@example.com")

      # The token is kept (encrypted) so the opt-in watchlist sync has a credential to use;
      # keeping it is not opting in.
      assert Cinder.Accounts.plex_token(user) == "plex-auth-token"
      refute user.plex_watchlist_sync
    end

    # SECURITY: an attacker can relay the plex.tv PIN link to an admin who has linked Plex;
    # approving it must not hand the attacker an admin session (or a stored token).
    test "an admin with a linked Plex account is refused: no session, no token, flash", %{
      conn: conn
    } do
      admin = admin_fixture() |> Ecto.Changeset.change(plex_id: 777) |> Repo.update!()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 98 -> {:ok, "admin-plex-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "admin-plex-token", [] ->
        {:ok, %{id: 777, email: "admin-plex@example.com", username: "the-admin"}}
      end)

      expect_shared([777])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 98)
        |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with your password"
      assert Cinder.Accounts.plex_token(Repo.reload!(admin)) == nil
    end

    test "a :user with a linked Plex account still signs in", %{conn: conn} do
      member = user_fixture() |> Ecto.Changeset.change(plex_id: 778) |> Repo.update!()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 97 -> {:ok, "member-plex-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "member-plex-token", [] ->
        {:ok, %{id: 778, email: "member@example.com", username: "member"}}
      end)

      expect_shared([778])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 97)
        |> get(~p"/auth/plex/callback")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Cinder.Accounts.plex_token(Repo.reload!(member)) == "member-plex-token"
    end

    test "with {:error, :pending} shows a flash error and does not log in", %{conn: conn} do
      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 99 -> {:error, :pending} end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 99)
        |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not completed"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "SECURITY: rejects an account that is neither the owner nor on the share list", %{
      conn: conn
    } do
      # With no admin, registration refuses on its own (:admin_required), and this test would
      # pass without the server gate.
      _admin = admin_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 99 -> {:ok, "plex-auth-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "plex-auth-token", [] ->
        {:ok, %{id: 666, email: "outsider@example.com", username: "outsider"}}
      end)

      expect_shared([665, 667])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 99)
        |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Repo.aggregate(User, :count) == count_before
    end

    # The share list holds ids next to the account's, never its own: an exact match is the gate.
    test "SECURITY: rejects an account whose id only resembles one on the share list", %{
      conn: conn
    } do
      _admin = admin_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 104 -> {:ok, "near-miss-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "near-miss-token", [] ->
        {:ok, %{id: 667, email: "near-miss@example.com", username: "near-miss"}}
      end)

      expect_shared([666, 668, 6670, -667])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 104)
        |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Repo.aggregate(User, :count) == count_before
    end

    test "with no pin in session redirects with an error and makes no plex.tv calls", %{
      conn: conn
    } do
      conn = conn |> init_test_session(%{}) |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "with :link intent, links Plex to the current user and redirects to /users/settings", %{
      conn: conn
    } do
      user = user_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 101 -> {:ok, "link-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "link-token", [] ->
        {:ok, %{id: 9001, email: "linkee@example.com", username: "linkee"}}
      end)

      expect_shared([9001])

      conn =
        conn
        # log_in_user/2 with no opts stamps authenticated_at at "now" — sudo-fresh — so this
        # stays the happy path even with the new sudo-mode gate on :link.
        |> log_in_user(user)
        |> put_session(:plex_pin_id, 101)
        |> put_session(:plex_intent, :link)
        |> get(~p"/auth/plex/callback")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "linked"
      assert Repo.aggregate(User, :count) == count_before
      linked = Repo.reload!(user)
      assert linked.plex_id == 9001
      assert Cinder.Accounts.plex_token(linked) == "link-token"
      refute linked.plex_watchlist_sync
    end

    test "an admin can still link Plex from settings (:link is not a sign-in)", %{conn: conn} do
      admin = admin_fixture()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 96 -> {:ok, "admin-link-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "admin-link-token", [] ->
        {:ok, %{id: 9100, email: "admin-link@example.com", username: "the-admin"}}
      end)

      expect_shared([9100])

      conn =
        conn
        |> log_in_user(admin)
        |> put_session(:plex_pin_id, 96)
        |> put_session(:plex_intent, :link)
        |> get(~p"/auth/plex/callback")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "linked"
      linked = Repo.reload!(admin)
      assert linked.plex_id == 9100
      assert Cinder.Accounts.plex_token(linked) == "admin-link-token"
    end

    test "SECURITY: with :link intent but a non-sudo-fresh session, does not link and shows a re-auth error",
         %{conn: conn} do
      user = user_fixture()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 150 -> {:ok, "stale-link-token"} end)

      conn =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        )
        |> put_session(:plex_pin_id, 150)
        |> put_session(:plex_intent, :link)
        |> get(~p"/auth/plex/callback")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "re-enter your password"

      refute Repo.reload!(user).plex_id
    end

    test "with :link intent whose account lacks server access, does not link and shows an error",
         %{conn: conn} do
      user = user_fixture()

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 102 -> {:ok, "link-token-2"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "link-token-2", [] ->
        {:ok, %{id: 9002, email: "outsider2@example.com", username: "outsider2"}}
      end)

      expect_shared([9003])

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:plex_pin_id, 102)
        |> put_session(:plex_intent, :link)
        |> get(~p"/auth/plex/callback")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute Repo.reload!(user).plex_id
    end

    test "the server owner's account signs in without the share list being read", %{conn: conn} do
      _admin = admin_fixture()

      expect(PlexAuthMock, :check_pin, fn 105 -> {:ok, "owner-sign-in-token"} end)

      expect(PlexAuthMock, :account, fn "owner-sign-in-token", [] ->
        {:ok, %{id: @owner_id, email: "owner-member@example.com", username: "owner"}}
      end)

      # verify_on_exit! fails the test on a server_machine_id or server_share_ids call.
      expect_owner()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 105)
        |> get(~p"/auth/plex/callback")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Repo.get_by(User, plex_id: @owner_id)
    end

    test "with :link intent, the server owner's account links without the share list being read",
         %{conn: conn} do
      user = user_fixture()

      expect(PlexAuthMock, :check_pin, fn 106 -> {:ok, "owner-link-token"} end)

      expect(PlexAuthMock, :account, fn "owner-link-token", [] ->
        {:ok, %{id: @owner_id, email: "owner-link@example.com", username: "owner"}}
      end)

      expect_owner()

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:plex_pin_id, 106)
        |> put_session(:plex_intent, :link)
        |> get(~p"/auth/plex/callback")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "linked"
      assert Repo.reload!(user).plex_id == @owner_id
    end

    # Decision 2 on #1212: an owner account or share list Cinder cannot read refuses, as an
    # unreadable /identity does.
    test "an unreadable owner account or share list refuses the sign-in", %{conn: conn} do
      _admin = admin_fixture()
      count_before = Repo.aggregate(User, :count)

      failures = [
        fn ->
          expect(PlexAuthMock, :account, fn @owner_token, [] ->
            {:error, {:plex_tv_status, 401}}
          end)
        end,
        fn ->
          expect_owner()
          expect(PlexAuthMock, :server_machine_id, fn [] -> {:ok, "machine-1"} end)

          expect(PlexAuthMock, :server_share_ids, fn @owner_token, "machine-1", [] ->
            {:error, {:plex_tv_status, 503}}
          end)
        end
      ]

      for {fail, pin} <- Enum.with_index(failures, 110) do
        expect(PlexAuthMock, :check_pin, fn ^pin -> {:ok, "shared-token"} end)

        expect(PlexAuthMock, :account, fn "shared-token", [] ->
          {:ok, %{id: 4242, email: "shared@example.com", username: "shared"}}
        end)

        fail.()

        conn =
          conn
          |> init_test_session(%{})
          |> put_session(:plex_pin_id, pin)
          |> get(~p"/auth/plex/callback")

        refute get_session(conn, :user_token)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Plex sign-in failed"
        assert redirected_to(conn) == ~p"/users/log-in"
        assert Repo.aggregate(User, :count) == count_before
      end
    end

    test "with :link intent, an unreadable owner account or share list does not link", %{
      conn: conn
    } do
      user = user_fixture()

      failures = [
        fn ->
          expect(PlexAuthMock, :account, fn @owner_token, [] -> {:error, :timeout} end)
        end,
        fn ->
          expect_owner()
          expect(PlexAuthMock, :server_machine_id, fn [] -> {:ok, "machine-1"} end)

          expect(PlexAuthMock, :server_share_ids, fn @owner_token, "machine-1", [] ->
            {:error, :unexpected_response}
          end)
        end
      ]

      for {fail, pin} <- Enum.with_index(failures, 120) do
        expect(PlexAuthMock, :check_pin, fn ^pin -> {:ok, "shared-link-token"} end)

        expect(PlexAuthMock, :account, fn "shared-link-token", [] ->
          {:ok, %{id: 4243, email: "shared-link@example.com", username: "shared"}}
        end)

        fail.()

        conn =
          conn
          |> log_in_user(user)
          |> put_session(:plex_pin_id, pin)
          |> put_session(:plex_intent, :link)
          |> get(~p"/auth/plex/callback")

        assert redirected_to(conn) == ~p"/users/settings"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"
        refute Repo.reload!(user).plex_id
      end
    end

    # SECURITY regression (the exact hole this rework closes): the Plex account's email matches
    # an existing admin's, but plex_id does not — this must never resolve to (or log in as) that
    # admin. `login_or_register_plex_user/1` rejects the create (users.email is uniquely
    # indexed), so the attacker is never logged in and the admin row is left untouched.
    test "SECURITY: on the :login path, an email collision with an existing admin never logs in as that admin",
         %{conn: conn} do
      admin = admin_fixture(email: "admin-collision@example.com")
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 103 -> {:ok, "collision-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "collision-token", [] ->
        {:ok, %{id: 5555, email: "admin-collision@example.com", username: "attacker"}}
      end)

      expect_shared([5555])

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 103)
        |> get(~p"/auth/plex/callback")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"

      reloaded = Repo.reload!(admin)
      assert reloaded.role == :admin
      assert reloaded.plex_id == nil
      assert Repo.aggregate(User, :count) == count_before
    end
  end
end
