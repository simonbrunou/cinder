defmodule Cinder.Accounts.OIDC.AssentTest do
  # The REAL Cinder.Accounts.OIDC.Assent / Assent path against a fake IdP served through the
  # Req.Test seam of Cinder.Accounts.OIDC.HTTPAdapter (OIDCMock never exercises nonce handling).
  # async: false — the provider settings live in global Application env.
  use ExUnit.Case, async: false

  alias Cinder.Accounts.OIDC
  alias Cinder.Accounts.OIDC.Assent, as: OIDCAssent
  alias Cinder.Accounts.OIDC.HTTPAdapter

  @issuer "https://id.example.com"
  @redirect "https://cinder.example.com/auth/oidc/callback"

  setup do
    original = Application.get_env(:cinder, OIDC)

    Application.put_env(:cinder, OIDC,
      issuer_url: @issuer,
      client_id: "cinder",
      client_secret: "s"
    )

    on_exit(fn -> Application.put_env(:cinder, OIDC, original) end)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    jwk = %{
      "kty" => "RSA",
      "kid" => "k1",
      "alg" => "RS256",
      "use" => "sig",
      "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
    }

    stub_idp(jwk, nil)
    %{jwk: jwk, pem: pem}
  end

  # Discovery + JWKS + token endpoint; the token endpoint answers with `id_token` (or none yet).
  defp stub_idp(jwk, id_token) do
    Req.Test.stub(Cinder.OIDCStub, fn conn ->
      body =
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            %{
              "issuer" => @issuer,
              "authorization_endpoint" => @issuer <> "/authorize",
              "token_endpoint" => @issuer <> "/token",
              "jwks_uri" => @issuer <> "/jwks",
              "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
            }

          "/jwks" ->
            %{"keys" => [jwk]}

          "/token" ->
            %{"access_token" => "at", "token_type" => "Bearer", "id_token" => id_token}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(body)
    end)
  end

  # Cinder's own provider config, with the HTTP seam pointed at the Req.Test fake IdP.
  defp fake_idp(config),
    do:
      Keyword.put(
        config,
        :http_adapter,
        {HTTPAdapter, source_origin: @issuer, plug: {Req.Test, Cinder.OIDCStub}}
      )

  defp start do
    assert {:ok, %{url: url, session_params: session_params}} =
             @redirect |> OIDC.authorize_config() |> fake_idp() |> OIDCAssent.authorize_url()

    %{"nonce" => url_nonce} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {url_nonce, session_params}
  end

  defp id_token(pem, nonce) do
    claims = %{
      "iss" => @issuer,
      "sub" => "subject-1",
      "aud" => "cinder",
      "exp" => System.system_time(:second) + 300,
      "iat" => System.system_time(:second),
      "email" => "person@example.com",
      "email_verified" => true,
      "nonce" => nonce
    }

    {:ok, token} = Assent.JWTAdapter.sign(claims, "RS256", pem, private_key_id: "k1")
    token
  end

  defp callback(session_params) do
    config =
      @redirect
      |> OIDC.config()
      |> fake_idp()
      |> Keyword.put(:session_params, session_params)

    OIDCAssent.callback(config, %{"code" => "code", "state" => session_params.state})
  end

  test "every authorization start gets its own unguessable nonce, shared by URL and session" do
    {url_a, session_a} = start()
    {url_b, session_b} = start()

    assert url_a == session_a.nonce
    assert url_b == session_b.nonce
    assert session_a.nonce != session_b.nonce
    # 32 random bytes, url-safe base64 without padding
    assert {:ok, bytes} = Base.url_decode64(session_a.nonce, padding: false)
    assert byte_size(bytes) == 32
  end

  test "a callback whose ID token carries the stored nonce passes nonce validation", %{
    jwk: jwk,
    pem: pem
  } do
    {_url_nonce, session_params} = start()
    stub_idp(jwk, id_token(pem, session_params.nonce))

    assert {:ok, %{user: %{"sub" => "subject-1", "email" => "person@example.com"}}} =
             callback(session_params)
  end

  test "a callback whose ID token carries another nonce fails without raising", %{
    jwk: jwk,
    pem: pem
  } do
    {_url_nonce, session_params} = start()
    {_other_url_nonce, other_session} = start()
    stub_idp(jwk, id_token(pem, other_session.nonce))

    assert {:error, reason} = callback(session_params)
    assert inspect(reason) =~ "nonce"
  end

  test "an ID token with the literal nonce true is not accepted", %{jwk: jwk, pem: pem} do
    {_url_nonce, session_params} = start()
    stub_idp(jwk, id_token(pem, "true"))

    assert {:error, _reason} = callback(session_params)
  end
end
