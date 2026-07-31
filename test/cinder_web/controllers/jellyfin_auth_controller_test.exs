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
        {:ok, %{id: "jf-1", name: "viewer"}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("viewer", "s3cret"))

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      created = Repo.get_by!(User, jellyfin_user_id: "jf-1")
      assert created.role == :user
      refute created.active
      assert created.jellyfin_username == "viewer"
      assert created.email =~ ~r/^viewer-[a-z0-9]+@jellyfin\.invalid$/
    end

    test "a second sign-in matches the same account by jellyfin_user_id", %{conn: conn} do
      _admin = admin_fixture()

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, 2, fn _u, _p ->
        {:ok, %{id: "jf-2", name: "repeat"}}
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
        {:ok, %{id: "jf-3", name: "someone"}}
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
        {:ok, %{id: "jf-4", name: "collide"}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("collide", "s3cret"))

      assert get_session(conn, :user_token)

      created = Repo.get_by!(User, jellyfin_user_id: "jf-4")
      assert created.id != admin.id
      assert created.role == :user

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
    # the "jellyfin:" namespace, a successful sign-in here would CLEAR the password-login budget
    # of any account whose email equals the Jellyfin username — handing an attacker a budget
    # reset between guesses.
    test "a Jellyfin sign-in never resets the password-login budget of a matching email", %{
      conn: conn
    } do
      _admin = admin_fixture()
      victim_key = {"127.0.0.1", "victim@example.com"}

      for _ <- 1..11, do: IpRateLimiter.check_and_register(:login_pair, victim_key)
      assert IpRateLimiter.check_and_register(:login_pair, victim_key) == :blocked

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn _u, _p ->
        {:ok, %{id: "jf-5", name: "victim"}}
      end)

      conn = post(conn, ~p"/auth/jellyfin", credentials("victim@example.com", "s3cret"))

      assert get_session(conn, :user_token)
      assert IpRateLimiter.check_and_register(:login_pair, victim_key) == :blocked
    end
  end

  describe "POST /auth/jellyfin — :link" do
    test "links Jellyfin to the current user and creates no account", %{conn: conn} do
      user = user_fixture()
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.JellyfinAuthMock, :authenticate, fn "linkee", "s3cret" ->
        {:ok, %{id: "jf-100", name: "linkee"}}
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
        {:ok, %{id: "jf-200", name: "taken"}}
      end)

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/auth/jellyfin", credentials("taken", "s3cret"))

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"
      refute Repo.reload!(user).jellyfin_user_id
    end
  end
end
