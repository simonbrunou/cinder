defmodule CinderWeb.JellyfinAuthRefusalLogTest do
  use CinderWeb.ConnCase

  import ExUnit.CaptureLog
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase
  import CinderWeb.SignInRefusalHelpers

  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.JellyfinAuthMock
  alias Cinder.Repo

  setup :verify_on_exit!

  setup do
    # Every request shares the harness peer address, so each test starts from a clean budget.
    IpRateLimiter.reset()
    :ok
  end

  # The username is an email address, so the secret check covers an email too.
  @username "secret.person@example.com"
  @password "secret-password-123"
  @token "secret-token-123"
  @secrets [@username, @password, @token, "secret-display-name"]

  defp credentials(username \\ @username, password \\ @password),
    do: %{"jellyfin" => %{"username" => username, "password" => password}}

  defp account(id, overrides \\ %{}),
    do: Map.merge(%{id: id, name: "secret-display-name", remote_access: true}, overrides)

  defp expect_authenticate(result),
    do: expect(JellyfinAuthMock, :authenticate, fn @username, @password -> result end)

  defp sign_in(conn, params \\ credentials()),
    do: with_log(fn -> post(conn, ~p"/auth/jellyfin", params) end)

  defp link(conn, user, login_opts \\ []),
    do: sign_in(log_in_user(conn, user, login_opts))

  defp stale, do: [token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)]

  describe "POST /auth/jellyfin, :login" do
    test "step=config when Jellyfin is not configured", %{conn: conn} do
      put_config(Cinder.Library.MediaServer.Jellyfin, url: nil)

      {conn, log} = sign_in(conn)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=login step=config reason=not_configured"
      )
    end

    test "step=throttle once the {ip, username} budget is spent", %{conn: conn} do
      expect(JellyfinAuthMock, :authenticate, 10, fn _username, _password ->
        {:error, :invalid_credentials}
      end)

      for _ <- 1..10, do: sign_in(conn)

      {conn, log} = sign_in(conn)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=login step=throttle reason=rate_limited"
      )
    end

    test "step=password when the password is empty", %{conn: conn} do
      {_conn, log} = sign_in(conn, credentials(@username, ""))

      assert_one_refusal(log, "jellyfin_signin refused intent=login step=password reason=empty")
    end

    test "step=params for a malformed POST", %{conn: conn} do
      {conn, log} = sign_in(conn, %{"jellyfin" => %{"username" => @username}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert_one_refusal(log, "jellyfin_signin refused intent=login step=params reason=malformed")
    end

    test "step=authenticate with Jellyfin's reason", %{conn: conn} do
      expect_authenticate({:error, :invalid_credentials})

      {conn, log} = sign_in(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Jellyfin sign-in failed"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=login step=authenticate reason=invalid_credentials"
      )
    end

    test "step=remote_access for a LAN-only user signing in from a public address", %{
      conn: conn
    } do
      expect_authenticate({:ok, account("jf-501", %{remote_access: false})})

      {_conn, log} = sign_in(%{conn | remote_ip: {203, 0, 113, 7}})

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=login step=remote_access reason=remote_access_denied"
      )
    end

    test "step=account_write when the account cannot be created", %{conn: conn} do
      # No admin exists yet, so registration refuses with :admin_required.
      expect_authenticate({:ok, account("jf-502")})

      {conn, log} = sign_in(conn)

      assert redirected_to(conn) == ~p"/users/log-in"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=login step=account_write reason=admin_required"
      )
    end
  end

  describe "POST /auth/jellyfin, :link" do
    test "step=sudo when the session is not sudo-fresh", %{conn: conn} do
      {conn, log} = link(conn, user_fixture(), stale())

      assert redirected_to(conn) == ~p"/users/settings"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=link step=sudo reason=reauth_required"
      )
    end

    test "step=account_write names only the changeset's fields with errors", %{conn: conn} do
      user_fixture() |> Ecto.Changeset.change(jellyfin_user_id: "jf-503") |> Repo.update!()
      expect_authenticate({:ok, account("jf-503")})

      {conn, log} = link(conn, user_fixture())

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not link"

      assert_one_refusal(
        log,
        "jellyfin_signin refused intent=link step=account_write reason=changeset:jellyfin_user_id"
      )
    end
  end

  test "no refusal line holds the username, the password or a token", %{conn: conn} do
    user_fixture() |> Ecto.Changeset.change(jellyfin_user_id: "jf-taken") |> Repo.update!()

    cases = [
      {"authenticate error with a response body",
       fn ->
         expect_authenticate(
           {:error,
            %Req.Response{
              status: 500,
              body: %{"AccessToken" => @token, "User" => %{"Name" => @username}}
            }}
         )
       end, &sign_in/1},
      {"authenticate error with an exception message",
       fn -> expect_authenticate({:error, RuntimeError.exception("#{@token} #{@password}")}) end,
       &sign_in/1},
      {"remote_access",
       fn -> expect_authenticate({:ok, account("jf-601", %{remote_access: false})}) end,
       &sign_in(%{&1 | remote_ip: {203, 0, 113, 7}})},
      {"account_write on login", fn -> expect_authenticate({:ok, account("jf-602")}) end,
       &sign_in/1},
      {"account_write on link", fn -> expect_authenticate({:ok, account("jf-taken")}) end,
       &link(&1, user_fixture())},
      {"password", fn -> :ok end, &sign_in(&1, credentials(@username, ""))},
      {"params", fn -> :ok end, &sign_in(&1, %{"jellyfin" => %{"username" => @username}})}
    ]

    for {label, mocks, request} <- cases do
      IpRateLimiter.reset()
      mocks.()
      {_conn, log} = request.(conn)
      refute_secrets(log, "jellyfin_signin", @secrets, label)
    end
  end
end
