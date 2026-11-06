defmodule CinderWeb.PlexAuthRefusalNoticeTest do
  # async: false: the throttle tests turn the global `:ip_rate_limiting` flag on and share the one
  # limiter table, and `Cinder.TestNotifier` broadcasts every test's events on one topic, so an
  # async neighbour's refusal could land in this test's mailbox.
  use CinderWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase

  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.PlexAuthMock
  alias Cinder.Accounts.User
  alias Cinder.Repo

  setup :verify_on_exit!

  defmodule Raising do
    @behaviour Cinder.Notifier
    @impl true
    def notify(_event), do: raise("transport down")
  end

  setup do
    Cinder.TestNotifier.subscribe()
    IpRateLimiter.reset()
    on_exit(&IpRateLimiter.reset/0)
    :ok
  end

  @email "member@example.com"
  @hour_ms 60 * 60 * 1000

  defp account(id, overrides \\ %{}),
    do: Map.merge(%{id: id, email: @email, username: "member"}, overrides)

  defp linked_user(plex_id, attrs \\ []),
    do: user_fixture(attrs) |> Ecto.Changeset.change(plex_id: plex_id) |> Repo.update!()

  # Mocks for one callback that plex.tv answers up to `step`, which refuses. `times` callbacks
  # each get the same answers.
  defp expect_refusal_at(step, plex_account, times \\ 1) do
    expect(PlexAuthMock, :check_pin, times, fn 1 -> {:ok, "token"} end)

    case step do
      :account ->
        expect(PlexAuthMock, :account, times, fn "token" -> {:error, {:plex_tv_status, 503}} end)

      _later ->
        expect(PlexAuthMock, :account, times, fn "token" -> {:ok, plex_account} end)
        expect_server_steps(step, times)
    end
  end

  defp expect_server_steps(:server_machine_id, times),
    do: expect(PlexAuthMock, :server_machine_id, times, fn -> {:error, :unexpected_response} end)

  defp expect_server_steps(step, times) do
    expect(PlexAuthMock, :server_machine_id, times, fn -> {:ok, "machine-1"} end)

    expect(PlexAuthMock, :resource_ids, times, fn "token" ->
      case step do
        :server_ids -> {:error, {:plex_tv_status, 500}}
        :server_access -> {:ok, ["another-server"]}
        :account_write -> {:ok, ["machine-1"]}
      end
    end)
  end

  defp login_callback(conn) do
    quiet(fn ->
      conn
      |> init_test_session(%{})
      |> put_session(:plex_pin_id, 1)
      |> get(~p"/auth/plex/callback")
    end)
  end

  defp link_callback(conn, user, login_opts \\ []) do
    quiet(fn ->
      conn
      |> log_in_user(user, login_opts)
      |> put_session(:plex_pin_id, 1)
      |> put_session(:plex_intent, :link)
      |> get(~p"/auth/plex/callback")
    end)
  end

  # Every refusal writes its `plex_signin refused` warning; these tests read the notices instead.
  defp quiet(request) do
    {conn, _log} = with_log(request)
    conn
  end

  defp stale, do: [token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)]

  defp assert_one_notice(%User{id: id}, step) do
    assert_receive {:notify, {:sign_in_refused, %User{id: ^id}, ^step}}
    refute_received {:notify, {:sign_in_refused, _user, _step}}
  end

  defp refute_notice, do: refute_received({:notify, {:sign_in_refused, _user, _step}})

  # The limiter is a fixed window from the first notice. Moving that start back stands in for
  # waiting: it changes nothing but the row's age.
  defp age_window(%User{id: id}, ms) do
    key = {:sign_in_refused, id}
    [{^key, _count, started}] = :ets.lookup(:cinder_ip_attempts, key)
    true = :ets.update_element(:cinder_ip_attempts, key, {3, started - ms})
  end

  describe ":login, a Plex account a user has linked" do
    # A username plex.tv reports as a number makes the account write's changeset fail.
    for {step, username} <- [
          server_machine_id: "member",
          server_ids: "member",
          server_access: "member",
          account_write: 12_345
        ] do
      test "refused at #{step} sends one notice naming the user and the step", %{conn: conn} do
        user = linked_user(42)
        expect_refusal_at(unquote(step), account(42, %{username: unquote(username)}))

        conn = login_callback(conn)

        assert redirected_to(conn) == ~p"/users/log-in"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Plex sign-in failed"
        assert_one_notice(user, unquote(step))
      end
    end

    test "an admin's Plex sign-in refused at account_write sends nothing", %{conn: conn} do
      admin_fixture() |> Ecto.Changeset.change(plex_id: 43) |> Repo.update!()
      expect_refusal_at(:account_write, account(43))

      conn = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with your password"
      refute_notice()
    end

    # The brief leaves out only the `:admin_password_required` reason, so an admin refused at an
    # earlier step is a refused sign-in like any other.
    test "an admin's Plex sign-in refused at server_access names the admin", %{conn: conn} do
      admin = admin_fixture() |> Ecto.Changeset.change(plex_id: 44) |> Repo.update!()
      expect_refusal_at(:server_access, account(44))

      login_callback(conn)

      assert_one_notice(admin, :server_access)
    end

    test "refused at account sends nothing: plex.tv named no account", %{conn: conn} do
      linked_user(45)
      expect_refusal_at(:account, nil)

      conn = login_callback(conn)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute_notice()
    end
  end

  describe ":login, nothing to report" do
    test "a Plex account no user has linked, refused at server_access", %{conn: conn} do
      linked_user(46)
      expect_refusal_at(:server_access, account(4600))

      conn = login_callback(conn)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute_notice()
    end

    test "a Plex account with no email that no user has linked (:no_email)", %{conn: conn} do
      _admin = admin_fixture()
      expect_refusal_at(:account_write, account(4700, %{email: nil}))

      conn = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no email address"
      refute_notice()
    end

    test "a PIN plex.tv has not linked yet (:pending)", %{conn: conn} do
      linked_user(48)
      expect(PlexAuthMock, :check_pin, fn 1 -> {:error, :pending} end)

      conn = login_callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not completed"
      refute_notice()
    end

    test "a session that holds no PIN", %{conn: conn} do
      linked_user(49)

      conn = quiet(fn -> conn |> init_test_session(%{}) |> get(~p"/auth/plex/callback") end)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
      refute_notice()
    end
  end

  describe ":link" do
    for step <- [:account, :server_access] do
      test "refused at #{step} sends one notice naming the signed-in user", %{conn: conn} do
        user = user_fixture()
        expect_refusal_at(unquote(step), account(50))

        conn = link_callback(conn, user)

        assert redirected_to(conn) == ~p"/users/settings"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"
        assert_one_notice(user, unquote(step))
      end
    end

    test "refused at account_write, a Plex account another user linked, names the signed-in user",
         %{conn: conn} do
      linked_user(51)
      user = user_fixture()
      expect_refusal_at(:account_write, account(51))

      conn = link_callback(conn, user)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"
      assert_one_notice(user, :account_write)
    end

    test "a callback from a session that is not sudo-fresh sends nothing", %{conn: conn} do
      expect(PlexAuthMock, :check_pin, fn 1 -> {:ok, "token"} end)

      conn = link_callback(conn, user_fixture(), stale())

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "re-enter your password"
      refute_notice()
    end

    test "a PIN check that fails sends nothing", %{conn: conn} do
      expect(PlexAuthMock, :check_pin, fn 1 -> {:error, {:plex_tv_status, 503}} end)

      conn = link_callback(conn, user_fixture())

      assert redirected_to(conn) == ~p"/users/settings"
      refute_notice()
    end

    test "a PIN plex.tv cannot start sends nothing", %{conn: conn} do
      expect(PlexAuthMock, :create_pin, fn -> {:error, {:plex_tv_status, 503}} end)

      conn = quiet(fn -> conn |> log_in_user(user_fixture()) |> get(~p"/auth/plex") end)

      assert redirected_to(conn) == ~p"/users/settings"
      refute_notice()
    end
  end

  describe "at most one notice per user per hour" do
    setup do
      put_env(:ip_rate_limiting, true)
      :ok
    end

    test "eight refusals send one notice, a second user gets its own, and the next hour another",
         %{conn: conn} do
      first = linked_user(60)
      second = linked_user(61)

      expect_refusal_at(:server_access, account(60), 8)
      for _ <- 1..8, do: login_callback(conn)
      assert_one_notice(first, :server_access)

      expect_refusal_at(:server_access, account(61))
      login_callback(conn)
      assert_one_notice(second, :server_access)

      age_window(first, @hour_ms - 60_000)
      expect_refusal_at(:server_access, account(60))
      login_callback(conn)
      refute_notice()

      age_window(first, 60_000)
      expect_refusal_at(:server_access, account(60))
      login_callback(conn)
      assert_one_notice(first, :server_access)
    end

    test "a refused :link and a refused :login of one user share the hour", %{conn: conn} do
      user = linked_user(62)

      expect_refusal_at(:server_access, account(62))
      link_callback(conn, user)
      assert_one_notice(user, :server_access)

      expect_refusal_at(:server_access, account(62))
      login_callback(conn)
      refute_notice()
    end

    test "a refusal at another step in the same hour sends nothing more", %{conn: conn} do
      user = linked_user(63)

      expect_refusal_at(:server_access, account(63))
      login_callback(conn)
      assert_one_notice(user, :server_access)

      expect_refusal_at(:server_ids, account(63))
      login_callback(conn)
      refute_notice()
    end
  end

  # The test env turns `:ip_rate_limiting` off, as the `:user_password` bucket honours it too:
  # user ids repeat across sandboxed tests, so a bucket that ignored the flag would carry one
  # test's count into the next and hide that test's notice.
  test "with :ip_rate_limiting off, every refusal sends its notice", %{conn: conn} do
    put_env(:ip_rate_limiting, false)
    user = linked_user(64)

    expect_refusal_at(:server_access, account(64), 2)
    login_callback(conn)
    assert_one_notice(user, :server_access)
    login_callback(conn)
    assert_one_notice(user, :server_access)
  end

  describe "best effort" do
    test "a notifier that raises changes neither the redirect nor the flash, and logs no email",
         %{conn: conn} do
      put_env(:notifier, Raising)
      linked_user(70, email: @email)
      expect_refusal_at(:server_access, account(70))

      {conn, log} =
        with_log(fn ->
          conn
          |> init_test_session(%{})
          |> put_session(:plex_pin_id, 1)
          |> get(~p"/auth/plex/callback")
        end)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Plex sign-in failed"
      assert log =~ "notifier failed for sign_in_refused #"
      refute log =~ @email
    end
  end
end
