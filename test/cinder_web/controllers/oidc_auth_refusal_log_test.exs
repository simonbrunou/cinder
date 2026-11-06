defmodule CinderWeb.OIDCAuthRefusalLogTest do
  use CinderWeb.ConnCase

  import ExUnit.CaptureLog
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.ConfigCase
  import CinderWeb.SignInRefusalHelpers

  alias Assent.HTTPAdapter.HTTPResponse
  alias Cinder.Accounts.OIDCMock

  setup :verify_on_exit!

  @token "secret-token-123"
  @id_token "secret-id-token"
  @email "secret-person@example.com"
  @client_secret "secret-client-secret"
  @secrets [@token, @id_token, @email, @client_secret, "secret-name"]

  setup do
    put_config(Cinder.Accounts.OIDC,
      issuer_url: "https://id.example.com",
      client_id: "cinder",
      client_secret: @client_secret
    )

    :ok
  end

  defp start(conn), do: with_log(fn -> get(conn, ~p"/auth/oidc") end)

  defp callback(conn) do
    with_log(fn ->
      conn
      |> init_test_session(%{oidc_session_params: %{state: "state"}})
      |> get(~p"/auth/oidc/callback?state=state&code=code")
    end)
  end

  defp expect_callback(result), do: expect(OIDCMock, :callback, fn _config, _params -> result end)

  defp tokens, do: %{"access_token" => @token, "id_token" => @id_token}

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{"sub" => "oidc-1", "email" => @email, "email_verified" => true, "name" => "secret-name"},
      overrides
    )
  end

  describe "GET /auth/oidc" do
    test "step=config when OIDC is not configured", %{conn: conn} do
      put_config(Cinder.Accounts.OIDC, issuer_url: nil)

      {conn, log} = start(conn)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert_one_refusal(log, "oidc_signin refused step=config reason=not_configured")
    end

    test "step=authorize_url with the error's module and the struct in its reason", %{
      conn: conn
    } do
      expect(OIDCMock, :authorize_url, fn _config ->
        {:error,
         %Assent.ServerUnreachableError{
           http_adapter: Cinder.Accounts.OIDC.HTTPAdapter,
           request_url: "https://id.example.com/.well-known/openid-configuration",
           reason: %Req.TransportError{reason: :econnrefused}
         }}
      end)

      {_conn, log} = start(conn)

      assert_one_refusal(
        log,
        "oidc_signin refused step=authorize_url " <>
          "reason=Assent.ServerUnreachableError(Req.TransportError(econnrefused))"
      )
    end

    test "step=authorize_url reason=unexpected_response without session params", %{conn: conn} do
      expect(OIDCMock, :authorize_url, fn _config ->
        {:ok, %{url: "https://id.example.com/authorize", session_params: nil}}
      end)

      {_conn, log} = start(conn)

      assert_one_refusal(
        log,
        "oidc_signin refused step=authorize_url reason=unexpected_response"
      )
    end

    test "step=authorize_url reason=insecure_url for an http authorization endpoint", %{
      conn: conn
    } do
      expect(OIDCMock, :authorize_url, fn _config ->
        {:ok, %{url: "http://id.example.com/authorize", session_params: %{state: "state"}}}
      end)

      {conn, log} = start(conn)

      refute get_session(conn, :oidc_session_params)
      assert_one_refusal(log, "oidc_signin refused step=authorize_url reason=insecure_url")
    end
  end

  describe "GET /auth/oidc/callback" do
    test "step=session when the session holds no parameters", %{conn: conn} do
      {conn, log} = with_log(fn -> get(conn, ~p"/auth/oidc/callback?state=forged&code=code") end)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OpenID sign-in failed"
      assert_one_refusal(log, "oidc_signin refused step=session reason=missing_params")
    end

    test "step=callback with the provider's error code", %{conn: conn} do
      expect_callback(
        {:error, %Assent.CallbackError{message: "The user denied it", error: "access_denied"}}
      )

      {_conn, log} = callback(conn)

      assert_one_refusal(
        log,
        "oidc_signin refused step=callback reason=Assent.CallbackError(access_denied)"
      )
    end

    test "step=callback quotes an ID-token check's message", %{conn: conn} do
      expect_callback({:error, "The ID Token has expired"})

      {_conn, log} = callback(conn)

      assert_one_refusal(
        log,
        ~s(oidc_signin refused step=callback reason="The ID Token has expired")
      )
    end

    test "step=callback reason=unexpected_response for a success with no user", %{conn: conn} do
      expect_callback({:ok, %{token: tokens()}})

      {_conn, log} = callback(conn)

      assert_one_refusal(log, "oidc_signin refused step=callback reason=unexpected_response")
    end

    test "step=claims for claims with no subject", %{conn: conn} do
      expect_callback({:ok, %{user: claims(%{"sub" => nil}), token: tokens()}})

      {_conn, log} = callback(conn)

      assert_one_refusal(log, "oidc_signin refused step=claims reason=invalid_claims")
    end

    test "step=account_write reason=identity_conflict keeps the conflict flash", %{conn: conn} do
      admin_fixture(email: @email) |> set_password()
      expect_callback({:ok, %{user: claims(), token: tokens()}})

      {conn, log} = callback(conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "ask an administrator"
      assert_one_refusal(log, "oidc_signin refused step=account_write reason=identity_conflict")
    end

    test "step=account_write with the write's reason", %{conn: conn} do
      expect_callback({:ok, %{user: claims(%{"email_verified" => false}), token: tokens()}})

      {_conn, log} = callback(conn)

      assert_one_refusal(
        log,
        "oidc_signin refused step=account_write reason=verified_email_required"
      )
    end
  end

  test "no refusal line holds a token, an email or the client secret", %{conn: conn} do
    response = %HTTPResponse{
      status: 400,
      body: %{"access_token" => @token, "id_token" => @id_token, "email" => @email}
    }

    admin_fixture(email: "taken-" <> @email) |> set_password()

    cases = [
      {"invalid response", {:error, %Assent.InvalidResponseError{response: response}}},
      {"request error",
       {:error, %Assent.RequestError{message: "Unauthorized token", response: response}}},
      {"unexpected response", {:error, %Assent.UnexpectedResponseError{response: response}}},
      {"exception message",
       {:error, RuntimeError.exception("#{@token} #{@email} #{@client_secret}")}},
      # Assent's ID-token checks quote the claim they reject.
      {"ID-token check quoting a claim", {:error, ~s(Invalid issuer "#{@email}" in ID Token)}},
      {"string reason holding an email", {:error, "rejected #{@email}"}},
      {"success with no user", {:ok, %{token: tokens()}}},
      {"claims", {:ok, %{user: claims(%{"sub" => nil}), token: tokens()}}},
      {"identity_conflict",
       {:ok, %{user: claims(%{"email" => "taken-" <> @email}), token: tokens()}}},
      {"account_write", {:ok, %{user: claims(%{"email_verified" => false}), token: tokens()}}}
    ]

    for {label, result} <- cases do
      expect_callback(result)
      {_conn, log} = callback(conn)
      refute_secrets(log, "oidc_signin", @secrets, label)
    end
  end
end
