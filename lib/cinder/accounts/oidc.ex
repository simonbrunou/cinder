defmodule Cinder.Accounts.OIDC do
  @moduledoc """
  Generic OpenID Connect sign-in seam. The production implementation delegates discovery,
  authorization-code + PKCE exchange, nonce/state checks, and ID-token/JWKS validation to Assent.

  The one configured provider lives in `Cinder.Settings` under issuer URL, client id, and encrypted
  client secret. Cinder requests only `openid email profile`; it stores no provider tokens.
  """

  alias Cinder.Util

  @callback authorize_url(keyword()) ::
              {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  @callback callback(keyword(), map()) ::
              {:ok, %{required(:user) => map(), optional(:token) => map()}} | {:error, term()}

  @doc "True when an absolute HTTPS issuer, client id, and client secret are configured."
  def configured? do
    config = Application.get_env(:cinder, __MODULE__, [])

    valid_issuer?(config[:issuer_url]) and Util.present?(config[:client_id]) and
      Util.present?(config[:client_secret])
  end

  @doc false
  def config(redirect_uri) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: issuer(),
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      redirect_uri: redirect_uri,
      http_adapter: {Cinder.Accounts.OIDC.HTTPAdapter, source_origin: issuer()},
      authorization_params: [scope: "email profile"],
      nonce: true,
      code_verifier: true
    ]
  end

  @doc false
  def account(%{} = claims) do
    case claims["sub"] do
      subject when is_binary(subject) and subject != "" ->
        {:ok,
         %{
           issuer: issuer(),
           subject: subject,
           email: claims["email"],
           email_verified: claims["email_verified"] == true,
           name: claims["name"] || claims["preferred_username"]
         }}

      _ ->
        {:error, :invalid_claims}
    end
  end

  @doc false
  def issuer do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:issuer_url, "")
    |> String.trim()
    |> String.trim_trailing("/")
  end

  @doc false
  def impl, do: Application.fetch_env!(:cinder, :oidc_auth)

  @doc false
  def secure_endpoint?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} -> Util.present?(host)
      _ -> false
    end
  end

  def secure_endpoint?(_value), do: false

  defp valid_issuer?(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}} ->
        Util.present?(host)

      _ ->
        false
    end
  end

  defp valid_issuer?(_value), do: false
end
