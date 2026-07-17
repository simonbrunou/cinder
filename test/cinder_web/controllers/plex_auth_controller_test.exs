defmodule CinderWeb.PlexAuthControllerTest do
  use CinderWeb.ConnCase

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Accounts.User
  alias Cinder.Repo

  setup :verify_on_exit!

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
      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 99 -> {:ok, "plex-auth-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "plex-auth-token" ->
        {:ok, %{id: 555, email: "newplex@example.com", username: "newplex"}}
      end)

      expect(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn -> {:ok, "machine-1"} end)
      expect(Cinder.Accounts.PlexAuthMock, :server_ids, fn _token -> {:ok, ["machine-1"]} end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:plex_pin_id, 99)
        |> get(~p"/auth/plex/callback")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Repo.get_by(User, email: "newplex@example.com")
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

    test "SECURITY: rejects an account whose server_ids don't include the configured server", %{
      conn: conn
    } do
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 99 -> {:ok, "plex-auth-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "plex-auth-token" ->
        {:ok, %{id: 666, email: "outsider@example.com", username: "outsider"}}
      end)

      expect(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn -> {:ok, "machine-1"} end)

      expect(Cinder.Accounts.PlexAuthMock, :server_ids, fn _token ->
        {:ok, ["some-other-machine"]}
      end)

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

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "link-token" ->
        {:ok, %{id: 9001, email: "linkee@example.com", username: "linkee"}}
      end)

      expect(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn -> {:ok, "machine-1"} end)
      expect(Cinder.Accounts.PlexAuthMock, :server_ids, fn _token -> {:ok, ["machine-1"]} end)

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
      assert Repo.reload!(user).plex_id == 9001
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

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "link-token-2" ->
        {:ok, %{id: 9002, email: "outsider2@example.com", username: "outsider2"}}
      end)

      expect(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn -> {:ok, "machine-1"} end)

      expect(Cinder.Accounts.PlexAuthMock, :server_ids, fn _token ->
        {:ok, ["some-other-machine"]}
      end)

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

    # SECURITY regression (the exact hole this rework closes): the Plex account's email matches
    # an existing admin's, but plex_id does not — this must never resolve to (or log in as) that
    # admin. `login_or_register_plex_user/1` rejects the create (users.email is uniquely
    # indexed), so the attacker is never logged in and the admin row is left untouched.
    test "SECURITY: on the :login path, an email collision with an existing admin never logs in as that admin",
         %{conn: conn} do
      admin = admin_fixture(email: "admin-collision@example.com")
      count_before = Repo.aggregate(User, :count)

      expect(Cinder.Accounts.PlexAuthMock, :check_pin, fn 103 -> {:ok, "collision-token"} end)

      expect(Cinder.Accounts.PlexAuthMock, :account, fn "collision-token" ->
        {:ok, %{id: 5555, email: "admin-collision@example.com", username: "attacker"}}
      end)

      expect(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn -> {:ok, "machine-1"} end)
      expect(Cinder.Accounts.PlexAuthMock, :server_ids, fn _token -> {:ok, ["machine-1"]} end)

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
