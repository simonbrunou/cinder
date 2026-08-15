defmodule CinderWeb.OIDCAuthControllerTest do
  use CinderWeb.ConnCase

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Accounts.User
  alias Cinder.Repo

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cinder, Cinder.Accounts.OIDC)

    Application.put_env(:cinder, Cinder.Accounts.OIDC,
      issuer_url: "https://id.example.com",
      client_id: "cinder",
      client_secret: "secret"
    )

    on_exit(fn -> Application.put_env(:cinder, Cinder.Accounts.OIDC, original) end)
    :ok
  end

  test "start stores Assent's one-use state and redirects to the provider", %{conn: conn} do
    expect(Cinder.Accounts.OIDCMock, :authorize_url, fn config ->
      assert config[:base_url] == "https://id.example.com"
      assert config[:nonce]
      assert config[:code_verifier]
      assert config[:authorization_params] == [scope: "email profile"]

      {:ok,
       %{
         url: "https://id.example.com/authorize?state=state",
         session_params: %{state: "state", nonce: "nonce", code_verifier: "verifier"}
       }}
    end)

    conn = get(conn, ~p"/auth/oidc")

    assert redirected_to(conn) == "https://id.example.com/authorize?state=state"
    assert get_session(conn, :oidc_session_params).state == "state"
  end

  test "callback validates through the strategy and creates a pending signed-in user", %{
    conn: conn
  } do
    _admin = admin_fixture()

    expect(Cinder.Accounts.OIDCMock, :callback, fn config, params ->
      assert config[:session_params] == %{state: "state", nonce: "nonce"}
      assert params["state"] == "state"
      assert params["code"] == "code"

      {:ok,
       %{
         user: %{
           "sub" => "oidc-42",
           "email" => "new-oidc@example.com",
           "email_verified" => true,
           "name" => "OIDC User"
         },
         token: %{}
       }}
    end)

    conn =
      conn
      |> init_test_session(%{oidc_session_params: %{state: "state", nonce: "nonce"}})
      |> get(~p"/auth/oidc/callback?state=state&code=code")

    assert get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :oidc_session_params) == nil

    assert %{active: false, oidc_subject: "oidc-42"} =
             Repo.get_by!(User, email: "new-oidc@example.com")
  end

  test "start refuses an insecure authorization endpoint", %{conn: conn} do
    expect(Cinder.Accounts.OIDCMock, :authorize_url, fn _config ->
      {:ok,
       %{
         url: "http://id.example.com/authorize?state=state",
         session_params: %{state: "state"}
       }}
    end)

    conn = get(conn, ~p"/auth/oidc")

    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :oidc_session_params)
  end

  test "callback without matching session state fails before reaching the provider", %{conn: conn} do
    conn = get(conn, ~p"/auth/oidc/callback?state=forged&code=code")

    refute get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OpenID sign-in failed"
  end

  test "unverified email fails closed without creating an account", %{conn: conn} do
    _admin = admin_fixture()

    expect(Cinder.Accounts.OIDCMock, :callback, fn _config, _params ->
      {:ok,
       %{
         user: %{
           "sub" => "oidc-unverified",
           "email" => "unverified@example.com",
           "email_verified" => false
         }
       }}
    end)

    conn =
      conn
      |> init_test_session(%{oidc_session_params: %{state: "state"}})
      |> get(~p"/auth/oidc/callback?state=state&code=code")

    refute get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/users/log-in"
    refute Repo.get_by(User, email: "unverified@example.com")
  end
end
