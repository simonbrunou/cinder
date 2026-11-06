defmodule CinderWeb.OIDCAuthController do
  @moduledoc """
  Generic OIDC authorization-code sign-in. Assent owns discovery, state, nonce, PKCE, token
  exchange, and signature/claim validation; this controller keeps its one-use session parameters
  in Cinder's signed, HTTP-only browser session and maps only the verified identity into Accounts.

  Every failure writes one `oidc_signin refused` warning naming the step that refused and its
  reason (`CinderWeb.SignInRefusal`), then flashes and redirects to `/users/log-in`.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.OIDC
  alias CinderWeb.SignInRefusal

  def start(conn, _params) do
    if OIDC.configured?(),
      do: start_authorization(conn),
      else: refuse(conn, SignInRefusal.refusal(:config, :not_configured))
  end

  defp start_authorization(conn) do
    case OIDC.impl().authorize_url(OIDC.authorize_config(callback_url())) do
      {:ok, %{url: url, session_params: session_params}} when is_map(session_params) ->
        if OIDC.secure_endpoint?(url) do
          conn
          |> put_session(:oidc_session_params, session_params)
          |> redirect(external: url)
        else
          refuse(conn, SignInRefusal.refusal(:authorize_url, :insecure_url))
        end

      {:ok, _response} ->
        refuse(conn, SignInRefusal.refusal(:authorize_url, :unexpected_response))

      {:error, reason} ->
        refuse(conn, SignInRefusal.refusal(:authorize_url, reason))
    end
  end

  def callback(conn, params) do
    session_params = get_session(conn, :oidc_session_params)
    conn = delete_session(conn, :oidc_session_params)

    with {:ok, session_params} <- stored_session_params(session_params),
         {:ok, claims} <- verified_claims(session_params, params),
         {:ok, account} <- SignInRefusal.at(:claims, OIDC.account(claims)),
         {:ok, user} <-
           SignInRefusal.at(:account_write, Accounts.login_or_register_oidc_user(account)) do
      CinderWeb.UserAuth.log_in_user(conn, user)
    else
      {:refused, _step, _reason, _fields} = refusal -> refuse(conn, refusal)
    end
  end

  defp stored_session_params(%{} = session_params), do: {:ok, session_params}
  defp stored_session_params(_missing), do: SignInRefusal.refusal(:session, :missing_params)

  # The strategy's success carries the provider's tokens next to the claims, so a response with no
  # `:user` is refused by name and never handed to the log.
  defp verified_claims(session_params, params) do
    config = Keyword.put(OIDC.config(callback_url()), :session_params, session_params)

    case OIDC.impl().callback(config, params) do
      {:ok, %{user: claims}} -> {:ok, claims}
      {:ok, _response} -> SignInRefusal.refusal(:callback, :unexpected_response)
      error -> SignInRefusal.at(:callback, error)
    end
  end

  defp callback_url, do: url(~p"/auth/oidc/callback")

  # Every failure path ends here: one warning line naming the step and the reason, then the flash
  # and the redirect.
  defp refuse(conn, {:refused, _step, reason, _fields} = refusal) do
    SignInRefusal.warn(:oidc, refusal)

    conn
    |> put_flash(:error, failure_message(reason))
    |> redirect(to: ~p"/users/log-in")
  end

  # The verified email already belongs to an account with its own sign-in method. Attaching the
  # identity there is refused (Accounts.login_or_register_oidc_user/1), so say what to do instead.
  # Reaching this needs a provider-verified email, so it reveals nothing to a stranger.
  defp failure_message(:identity_conflict) do
    gettext(
      "An account already exists for this email. Sign in the way you did before, or ask an administrator."
    )
  end

  defp failure_message(_reason), do: gettext("OpenID sign-in failed. Please try again.")
end
