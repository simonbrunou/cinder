defmodule CinderWeb.OIDCAuthController do
  @moduledoc """
  Generic OIDC authorization-code sign-in. Assent owns discovery, state, nonce, PKCE, token
  exchange, and signature/claim validation; this controller keeps its one-use session parameters
  in Cinder's signed, HTTP-only browser session and maps only the verified identity into Accounts.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.OIDC

  def start(conn, _params) do
    if OIDC.configured?(), do: start_authorization(conn), else: failed(conn)
  end

  defp start_authorization(conn) do
    case OIDC.impl().authorize_url(OIDC.config(callback_url())) do
      {:ok, %{url: url, session_params: session_params}} when is_map(session_params) ->
        if OIDC.secure_endpoint?(url) do
          conn
          |> put_session(:oidc_session_params, session_params)
          |> redirect(external: url)
        else
          failed(conn)
        end

      {:ok, _response} ->
        failed(conn)

      {:error, _reason} ->
        failed(conn)
    end
  end

  def callback(conn, params) do
    session_params = get_session(conn, :oidc_session_params)
    conn = delete_session(conn, :oidc_session_params)

    with %{} <- session_params,
         config = Keyword.put(OIDC.config(callback_url()), :session_params, session_params),
         {:ok, %{user: claims}} <- OIDC.impl().callback(config, params),
         {:ok, account} <- OIDC.account(claims),
         {:ok, user} <- Accounts.login_or_register_oidc_user(account) do
      CinderWeb.UserAuth.log_in_user(conn, user)
    else
      _ -> failed(conn)
    end
  end

  defp callback_url, do: url(~p"/auth/oidc/callback")

  defp failed(conn) do
    conn
    |> put_flash(:error, gettext("OpenID sign-in failed. Please try again."))
    |> redirect(to: ~p"/users/log-in")
  end
end
