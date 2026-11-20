defmodule CinderWeb.PasskeyAuthControllerTest do
  # async: false: tests turn the IP limiter on, shrink the challenge TTL and set the Basic-auth
  # env vars, all process-global.
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.ConfigCase, only: [put_env: 2]
  import Cinder.Test.PasskeyHelpers
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest, only: [live: 2]

  alias Cinder.Accounts
  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.UserPasskey
  alias Cinder.Repo
  alias Cinder.Test.SoftAuthenticator

  @generic "Passkey sign-in failed. Please try again."

  defp mint(conn) do
    conn = post(conn, ~p"/users/log-in/passkey/options")
    %{"publicKey" => options} = json_response(conn, 200)
    {conn, Base.url_decode64!(options["challenge"], padding: false)}
  end

  defp sign_in(conn, auth, opts \\ [], extra \\ %{}) do
    {conn, challenge} = mint(conn)
    assertion = SoftAuthenticator.assert(auth, challenge, rp().id, rp().origin, opts)
    post(conn, ~p"/users/log-in/passkey", %{"passkey" => Map.merge(assertion, extra)})
  end

  defp assert_refused(conn) do
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == @generic
    refute get_session(conn, :user_token)
    # A refused post spends the handle in the session too.
    refute get_session(conn, :passkey_challenge)
  end

  defp enable_ip_limits do
    put_env(:ip_rate_limiting, true)
    IpRateLimiter.reset()
    on_exit(&IpRateLimiter.reset/0)
  end

  setup do
    user = user_fixture()
    {passkey, auth} = register_passkey!(user)
    %{user: user, passkey: passkey, auth: auth}
  end

  describe "the relying party" do
    test "is the endpoint's URL in this env" do
      assert CinderWeb.Passkey.relying_party() == rp()
    end

    test "is the host and the origin of a production URL, with a port only when not the default" do
      assert CinderWeb.Passkey.relying_party("https://cinder.example.org") ==
               %{id: "cinder.example.org", origin: "https://cinder.example.org"}

      assert CinderWeb.Passkey.relying_party("https://cinder.example.org:443") ==
               %{id: "cinder.example.org", origin: "https://cinder.example.org"}

      assert CinderWeb.Passkey.relying_party("https://cinder.example.org:8443/") ==
               %{id: "cinder.example.org", origin: "https://cinder.example.org:8443"}
    end
  end

  describe "POST /users/log-in/passkey/options" do
    test "answers discoverable-credential options that require user verification", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in/passkey/options")

      assert %{"publicKey" => options} = json_response(conn, 200)
      assert options["rpId"] == "localhost"
      assert options["userVerification"] == "required"
      assert byte_size(Base.url_decode64!(options["challenge"], padding: false)) == 32
      refute Map.has_key?(options, "allowCredentials")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert is_binary(get_session(conn, :passkey_challenge))
    end

    test "counts against the client's own bucket and answers 429 past it", %{conn: conn} do
      enable_ip_limits()

      for _ <- 1..10,
          do: assert(json_response(post(conn, ~p"/users/log-in/passkey/options"), 200))

      conn = post(conn, ~p"/users/log-in/passkey/options")
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
      refute get_session(conn, :passkey_challenge)
    end

    test "the budget is per IPv6 /48: its /64s share one, another /48 has its own", _ctx do
      enable_ip_limits()
      from = fn ip -> %{build_conn() | remote_ip: ip} end

      for n <- 1..10 do
        conn = post(from.({0x2001, 0xDB8, 0, n, 0, 0, 0, 1}), ~p"/users/log-in/passkey/options")
        assert json_response(conn, 200)
      end

      conn = post(from.({0x2001, 0xDB8, 0, 11, 0, 0, 0, 1}), ~p"/users/log-in/passkey/options")
      assert json_response(conn, 429)

      conn = post(from.({0x2001, 0xDB8, 1, 1, 0, 0, 0, 1}), ~p"/users/log-in/passkey/options")
      assert json_response(conn, 200)
    end

    test "answers 503 and keeps no handle when the challenge store is full", %{conn: conn} do
      put_env(:passkey_challenge_max_entries, %{sign_in: 0})

      conn = post(conn, ~p"/users/log-in/passkey/options")

      assert json_response(conn, 503) == %{"error" => "unavailable"}
      refute get_session(conn, :passkey_challenge)
    end

    test "a session's new options drop the challenge its earlier options stored", %{conn: conn} do
      first = post(conn, ~p"/users/log-in/passkey/options")
      first_handle = get_session(first, :passkey_challenge)

      second = post(first, ~p"/users/log-in/passkey/options")
      second_handle = get_session(second, :passkey_challenge)

      refute second_handle == first_handle
      assert :ets.lookup(:cinder_passkey_challenges, first_handle) == []
      assert [_] = :ets.lookup(:cinder_passkey_challenges, second_handle)
    end
  end

  describe "POST /users/log-in/passkey" do
    test "a valid assertion signs the owner in with a fresh sudo window", ctx do
      conn = sign_in(ctx.conn, ctx.auth, sign_count: 1)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome back!"
      token = get_session(conn, :user_token)
      assert {user, _} = Accounts.get_user_by_session_token(token)
      assert user.id == ctx.user.id
      assert Accounts.sudo_mode?(user)
      refute get_session(conn, :passkey_challenge)
      refute conn.resp_cookies["_cinder_web_user_remember_me"]
      assert Repo.get!(UserPasskey, ctx.passkey.id).sign_count == 1
    end

    test "remember-me sets the remember-me cookie, as on the password form", ctx do
      conn = sign_in(ctx.conn, ctx.auth, [], %{"remember_me" => "true"})

      assert get_session(conn, :user_token)
      assert %{max_age: _} = conn.resp_cookies["_cinder_web_user_remember_me"]
    end

    test "the return-to path a protected page stored is where the sign-in lands", ctx do
      conn = get(ctx.conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert redirected_to(sign_in(conn, ctx.auth)) == ~p"/users/settings"
    end

    test "a pending user is signed in, and / and /my-requests send them to /pending",
         %{conn: conn} do
      pending = user_fixture()
      {_passkey, auth} = register_passkey!(pending)

      pending |> Ecto.Changeset.change(active: false) |> Repo.update!()

      conn = sign_in(conn, auth)
      assert get_session(conn, :user_token)

      assert {:error, {:redirect, %{to: "/pending"}}} = live(recycle(conn), ~p"/")
      assert {:error, {:redirect, %{to: "/pending"}}} = live(recycle(conn), ~p"/my-requests")
    end

    test "an unknown credential is refused", %{conn: conn} do
      assert_refused(sign_in(conn, SoftAuthenticator.new(user_handle: "x")))
    end

    test "a bad signature is refused", ctx do
      conn = sign_in(ctx.conn, ctx.auth, sign_count: 1, sign_with: SoftAuthenticator.new())
      assert_refused(conn)
      assert Repo.get!(UserPasskey, ctx.passkey.id).sign_count == 0
    end

    test "a replayed challenge is refused", ctx do
      {minted, challenge} = mint(ctx.conn)

      assertion =
        SoftAuthenticator.assert(ctx.auth, challenge, rp().id, rp().origin, sign_count: 1)

      first = post(minted, ~p"/users/log-in/passkey", %{"passkey" => assertion})
      assert get_session(first, :user_token)

      # The same session cookie, still holding the handle: the server already spent it.
      assert_refused(post(minted, ~p"/users/log-in/passkey", %{"passkey" => assertion}))
    end

    test "an expired challenge is refused", ctx do
      put_env(:passkey_challenge_ttl_ms, 50)
      {minted, challenge} = mint(ctx.conn)

      assertion =
        SoftAuthenticator.assert(ctx.auth, challenge, rp().id, rp().origin, sign_count: 1)

      Process.sleep(60)

      assert_refused(post(minted, ~p"/users/log-in/passkey", %{"passkey" => assertion}))
    end

    test "a sign-count regression is refused", ctx do
      assert get_session(sign_in(ctx.conn, ctx.auth, sign_count: 5), :user_token)
      assert_refused(sign_in(build_conn(), ctx.auth, sign_count: 3))
      assert Repo.get!(UserPasskey, ctx.passkey.id).sign_count == 5
    end

    test "a post with no challenge in its session is refused", ctx do
      {_minted, challenge} = mint(ctx.conn)

      assertion =
        SoftAuthenticator.assert(ctx.auth, challenge, rp().id, rp().origin, sign_count: 1)

      assert_refused(post(build_conn(), ~p"/users/log-in/passkey", %{"passkey" => assertion}))
      assert_refused(post(build_conn(), ~p"/users/log-in/passkey", %{}))
    end

    test "a client over the :login limit is refused before any check, and its challenge is spent",
         ctx do
      enable_ip_limits()
      {minted, challenge} = mint(ctx.conn)

      assertion =
        SoftAuthenticator.assert(ctx.auth, challenge, rp().id, rp().origin, sign_count: 1)

      for _ <- 1..10, do: IpRateLimiter.check_and_register(:login, "127.0.0.1")

      assert_refused(post(minted, ~p"/users/log-in/passkey", %{"passkey" => assertion}))
      assert Repo.get!(UserPasskey, ctx.passkey.id).sign_count == 0

      IpRateLimiter.reset()
      assert_refused(post(minted, ~p"/users/log-in/passkey", %{"passkey" => assertion}))
    end

    test "each attempt counts against the :login bucket password sign-in uses", _ctx do
      enable_ip_limits()

      for _ <- 1..9, do: assert_refused(sign_in(build_conn(), SoftAuthenticator.new()))
      assert IpRateLimiter.check_and_register(:login, "127.0.0.1") == :ok
      assert IpRateLimiter.check_and_register(:login, "127.0.0.1") == :blocked
    end
  end

  describe "a signed-in user" do
    test "refreshes the sudo window with their own passkey", ctx do
      stale = DateTime.add(DateTime.utc_now(:second), -2, :day)
      conn = log_in_user(ctx.conn, ctx.user, token_authenticated_at: stale)
      {before, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
      refute Accounts.sudo_mode?(before)

      conn = sign_in(conn, ctx.auth, sign_count: 1)

      {user, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
      assert user.id == ctx.user.id
      assert Accounts.sudo_mode?(user)
    end

    test "is refused another user's passkey and keeps the session as it was", ctx do
      other = user_fixture()
      {other_passkey, other_auth} = register_passkey!(other)
      stale = DateTime.add(DateTime.utc_now(:second), -2, :day)
      conn = log_in_user(ctx.conn, ctx.user, token_authenticated_at: stale)
      token = get_session(conn, :user_token)

      conn = sign_in(conn, other_auth, sign_count: 1)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @generic
      assert get_session(conn, :user_token) == token
      {user, _} = Accounts.get_user_by_session_token(token)
      assert user.id == ctx.user.id
      refute Accounts.sudo_mode?(user)
      assert Repo.get!(UserPasskey, other_passkey.id).sign_count == 0
    end
  end

  describe "the HTTP Basic gate" do
    setup do
      System.put_env("CINDER_BASIC_AUTH_USER", "admin")
      System.put_env("CINDER_BASIC_AUTH_PASSWORD", "secret")

      on_exit(fn ->
        System.delete_env("CINDER_BASIC_AUTH_USER")
        System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
      end)
    end

    test "answers 401 on both routes without the Basic header", %{conn: conn} do
      assert post(conn, ~p"/users/log-in/passkey/options").status == 401
      assert post(conn, ~p"/users/log-in/passkey", %{}).status == 401
    end

    test "lets both routes through with the Basic header", %{conn: conn} do
      header = "Basic " <> Base.encode64("admin:secret")
      conn = put_req_header(conn, "authorization", header)

      assert json_response(post(conn, ~p"/users/log-in/passkey/options"), 200)
      assert redirected_to(post(conn, ~p"/users/log-in/passkey", %{})) == ~p"/users/log-in"
    end
  end

  describe "logging" do
    # The test env logs from :warning up; the request and query lines this test reads come at
    # :info and :debug.
    setup do
      primary = Logger.level()
      on_exit(fn -> Logger.configure(level: primary) end)
      Logger.configure(level: :debug)
    end

    defp encodings(bytes) do
      [
        bytes,
        Base.url_encode64(bytes, padding: false),
        Base.encode64(bytes),
        Base.encode16(bytes, case: :lower),
        Base.encode16(bytes),
        inspect(bytes)
      ]
    end

    defp secrets(auth) do
      %{-2 => x, -3 => y} = SoftAuthenticator.cose_key(auth)
      encodings(auth.credential_id) ++ encodings(x) ++ encodings(y)
    end

    test "a refused and a successful sign-in log neither the credential id nor the public key",
         ctx do
      log =
        capture_log([level: :debug], fn ->
          sign_in(build_conn(), ctx.auth, sign_count: 1, sign_with: SoftAuthenticator.new())
          sign_in(build_conn(), ctx.auth, sign_count: 2)
        end)

      # Positive controls: the debug log ran, and the refusal wrote its line.
      assert log =~ "POST /users/log-in/passkey"
      assert log =~ "passkey_signin refused intent=login step=verify reason=bad_signature"
      assert log =~ "[FILTERED]"

      for secret <- secrets(ctx.auth), do: refute(String.contains?(log, secret))
    end
  end
end
