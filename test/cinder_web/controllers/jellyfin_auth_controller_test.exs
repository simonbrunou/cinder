defmodule CinderWeb.JellyfinAuthControllerTest do
  use CinderWeb.ConnCase

  import Mox
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase

  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.User
  alias Cinder.Repo

  setup :verify_on_exit!

  setup do
    # The {ip, username} bucket is always on (see IpRateLimiter's @moduledoc) and every test
    # request shares the harness peer address — start each test from a clean budget.
    IpRateLimiter.reset()
    :ok
  end

  defp credentials(username, password),
    do: %{"jellyfin" => %{"username" => username, "password" => password}}

  describe "POST /auth/jellyfin — :login" do
    test "valid credentials create a fresh pending :user and log in", %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn "viewer", "s3cret" ->
        {:ok, %{id: "jf-1", name: "viewer", remote_access: true}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("viewer", "s3cret"))

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      created = Repo.get_by!(User, jellyfin_user_id: "jf-1")
      assert created.role == :user
      refute created.active
      assert created.jellyfin_username == "viewer"
      assert created.email =~ ~r/^viewer-[a-z2-7]{10}@jellyfin\.invalid$/
    end

    test "a second sign-in matches the same account by jellyfin_user_id", %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, 2, fn _u, _p ->
        {:ok, %{id: "jf-2", name: "repeat", remote_access: true}}
      end)

      post(conn, ~p"/auth/jellyfin", credentials("repeat", "s3cret"))
      count_after_first = Repo.aggregate(User, :count)

      conn = post(conn, ~p"/auth/jellyfin", credentials("repeat", "s3cret"))

      assert get_session(conn, :user_token)
      assert Repo.aggregate(User, :count) == count_after_first
    end

    test "bad credentials are rejected and create no account", %{conn: conn} do
      _admin = admin_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn "viewer", "wrong" ->
        {:error, :invalid_credentials}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("viewer", "wrong"))

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Jellyfin sign-in failed"
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Repo.aggregate(User, :count) == count_before
    end

    # SECURITY: the first Jellyfin login ALWAYS creates a new regular user. An existing account
    # whose email happens to match must never be logged into or attached to — the only email
    # Cinder ever sees here is the synthetic one it derives itself.
    test "a first login never logs into an existing account that shares the email", %{conn: conn} do
      admin = admin_fixture(email: "someone@example.com")

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-3", name: "someone", remote_access: true}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("someone", "s3cret"))

      assert get_session(conn, :user_token)

      created = Repo.get_by!(User, jellyfin_user_id: "jf-3")
      assert created.id != admin.id
      assert created.role == :user

      reloaded = Repo.reload!(admin)
      assert reloaded.role == :admin
      assert reloaded.jellyfin_user_id == nil
    end

    # SECURITY: self-registration is open, so an address derivable from the Jellyfin display name
    # would let anyone squat it and permanently deny that user their first sign-in. The synthetic
    # address is randomized, so the squatter neither blocks the create nor gets logged into.
    test "an account squatting the name-derived address neither blocks sign-in nor is logged into",
         %{conn: conn} do
      admin = admin_fixture(email: "collide@jellyfin.invalid")

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-4", name: "collide", remote_access: true}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("collide", "s3cret"))

      created = Repo.get_by!(User, jellyfin_user_id: "jf-4")
      assert created.id != admin.id
      assert created.role == :user

      # The session belongs to the NEW account, not the squatter whose address it collided with.
      {session_user, _inserted_at} =
        conn |> get_session(:user_token) |> Cinder.Accounts.get_user_by_session_token()

      assert session_user.id == created.id

      reloaded = Repo.reload!(admin)
      assert reloaded.role == :admin
      assert reloaded.jellyfin_user_id == nil
    end

    test "with no Jellyfin server configured, redirects with an error and makes no call", %{
      conn: conn
    } do
      # verify_on_exit! with no `expect` means any call to authenticate/2 fails the test.
      put_config(Cinder.Library.MediaServer.Jellyfin, url: nil)

      conn = post(conn, ~p"/auth/jellyfin", credentials("viewer", "s3cret"))

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a malformed POST fails closed without calling Jellyfin", %{conn: conn} do
      conn = post(conn, ~p"/auth/jellyfin", %{"jellyfin" => %{"username" => "viewer"}})

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    # SECURITY: Jellyfin signs a passwordless user in on an empty password, and the request
    # comes from Cinder's LAN address — so an empty password must never be forwarded at all (an
    # unexpected Mox call fails the test), yet still spends the throttle budget.
    #
    # The username is unique to this test: the {ip, username} bucket is always on and this test
    # leaves it blocked for 15 minutes, so a shared name would block a later test's sign-in
    # (#686).
    test "an empty password is refused without calling Jellyfin and still counts as an attempt",
         %{conn: conn} do
      conn = post(conn, ~p"/auth/jellyfin", credentials("empty-password-user", ""))

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Jellyfin sign-in failed"
      assert redirected_to(conn) == ~p"/users/log-in"

      for _ <- 1..9, do: post(conn, ~p"/auth/jellyfin", credentials("empty-password-user", ""))

      # The 11th attempt — correct this time — is throttled: without the empty ones counting it
      # would reach the (unexpecting) mock and fail the test.
      conn = post(conn, ~p"/auth/jellyfin", credentials("empty-password-user", "s3cret"))
      refute get_session(conn, :user_token)
    end

    # SECURITY: `EnableRemoteAccess: false` means Jellyfin itself would refuse this user from the
    # internet; Cinder's request comes from the LAN, so the controller enforces it against the
    # browser's address instead.
    test "a remote-access-disabled user is refused from a public address, allowed from a LAN one",
         %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, 2, fn _u, _p ->
        {:ok, %{id: "jf-lan", name: "lan-only", remote_access: false}}
      end)

      public =
        post(
          %{conn | remote_ip: {203, 0, 113, 7}},
          ~p"/auth/jellyfin",
          credentials("lan-only", "s3cret")
        )

      refute get_session(public, :user_token)
      assert Phoenix.Flash.get(public.assigns.flash, :error) =~ "Jellyfin sign-in failed"
      assert redirected_to(public) == ~p"/users/log-in"
      refute Repo.get_by(User, jellyfin_user_id: "jf-lan")

      lan =
        post(
          %{conn | remote_ip: {192, 168, 1, 20}},
          ~p"/auth/jellyfin",
          credentials("lan-only", "s3cret")
        )

      assert get_session(lan, :user_token)
      assert Repo.get_by(User, jellyfin_user_id: "jf-lan")
    end

    test "an account that omits the remote-access flag fails closed from a public address",
         %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-noflag", name: "noflag"}}
      end)

      conn =
        post(
          %{conn | remote_ip: {203, 0, 113, 7}},
          ~p"/auth/jellyfin",
          credentials("noflag", "s3cret")
        )

      refute get_session(conn, :user_token)
      refute Repo.get_by(User, jellyfin_user_id: "jf-noflag")
    end

    # The normal deployment: an internet visitor behind cloudflared (public address) whose
    # Jellyfin policy allows remote access must still sign in.
    test "a remote-access-enabled user signs in from a public address", %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-remote", name: "remote", remote_access: true}}
      end)

      conn =
        post(
          %{conn | remote_ip: {203, 0, 113, 7}},
          ~p"/auth/jellyfin",
          credentials("remote", "s3cret")
        )

      assert get_session(conn, :user_token)
      assert Repo.get_by(User, jellyfin_user_id: "jf-remote")
    end

    test "attempts past the {ip, username} budget are blocked without reaching Jellyfin", %{
      conn: conn
    } do
      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, 10, fn _u, _p ->
        {:error, :invalid_credentials}
      end)

      for _ <- 1..10, do: post(conn, ~p"/auth/jellyfin", credentials("bruteforce", "guess"))

      # The 11th call never reaches the mock — an unexpected call would fail verify_on_exit!.
      conn = post(conn, ~p"/auth/jellyfin", credentials("BruteForce", "guess"))

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    # SECURITY: `:login_pair` is shared with password login, which keys on {ip, email}. Without
    # the `{:jellyfin, _}` namespace, a successful sign-in here would CLEAR the password-login
    # budget of any account whose email equals the Jellyfin username — handing an attacker a
    # budget reset between guesses.
    test "a Jellyfin sign-in never resets the password-login budget of a matching email", %{
      conn: conn
    } do
      _admin = admin_fixture()
      victim_key = {"127.0.0.1", "victim@example.com"}

      for _ <- 1..11, do: IpRateLimiter.check_and_register(:login_pair, victim_key)
      assert IpRateLimiter.check_and_register(:login_pair, victim_key) == :blocked

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-5", name: "victim", remote_access: true}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("victim@example.com", "s3cret"))

      assert get_session(conn, :user_token)
      assert IpRateLimiter.check_and_register(:login_pair, victim_key) == :blocked
    end

    # ...and the reverse direction, which is why the namespace is a TUPLE and not a
    # `"jellyfin:" <> …` string prefix: `:` is legal in an email local part, so a string prefix
    # leaves `jellyfin:victim@example.com` a registerable Cinder address whose password login
    # would clear the Jellyfin budget for username `victim@example.com` on every success.
    test "a password login by a `jellyfin:`-shaped email cannot reset the Jellyfin budget", %{
      conn: conn
    } do
      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, 10, fn _u, _p ->
        {:error, :invalid_credentials}
      end)

      for _ <- 1..10, do: post(conn, ~p"/auth/jellyfin", credentials("victim@example.com", "x"))

      # Exactly what UserSessionController.create/3 does when that squatted email logs in.
      IpRateLimiter.clear(:login_pair, {"127.0.0.1", "jellyfin:victim@example.com"})

      # Still blocked: the 11th attempt never reaches the mock (verify_on_exit! would fail).
      conn = post(conn, ~p"/auth/jellyfin", credentials("victim@example.com", "x"))

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /auth/jellyfin — :link" do
    test "links Jellyfin to the current user and creates no account", %{conn: conn} do
      user = user_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn "linkee", "s3cret" ->
        {:ok, %{id: "jf-100", name: "linkee", remote_access: true}}
      end)

      conn =
        conn
        # log_in_user/2 with no opts stamps authenticated_at at "now" — sudo-fresh.
        |> log_in_user(user)
        |> post(~p"/auth/jellyfin", credentials("linkee", "s3cret"))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "linked"
      assert Repo.aggregate(User, :count) == count_before

      linked = Repo.reload!(user)
      assert linked.jellyfin_user_id == "jf-100"
      assert linked.jellyfin_username == "linkee"
    end

    test "SECURITY: a non-sudo-fresh session does not link and never reaches Jellyfin", %{
      conn: conn
    } do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        )
        |> post(~p"/auth/jellyfin", credentials("linkee", "s3cret"))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "re-enter your password"
      refute Repo.reload!(user).jellyfin_user_id
    end

    test "a Jellyfin identity already linked elsewhere is refused", %{conn: conn} do
      _taken =
        user_fixture()
        |> Ecto.Changeset.change(jellyfin_user_id: "jf-200")
        |> Repo.update!()

      user = user_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-200", name: "taken", remote_access: true}}
      end)

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/auth/jellyfin", credentials("taken", "s3cret"))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"
      refute Repo.reload!(user).jellyfin_user_id
    end

    test "a remote-access-disabled user cannot be linked from a public address", %{conn: conn} do
      user = user_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-lan", name: "lan-only", remote_access: false}}
      end)

      conn =
        %{conn | remote_ip: {203, 0, 113, 7}}
        |> log_in_user(user)
        |> post(~p"/auth/jellyfin", credentials("lan-only", "s3cret"))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Jellyfin sign-in failed"
      refute Repo.reload!(user).jellyfin_user_id
    end

    test "an empty password is never forwarded when linking", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/auth/jellyfin", credentials("linkee", ""))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Jellyfin sign-in failed"
      refute Repo.reload!(user).jellyfin_user_id
    end
  end
end
