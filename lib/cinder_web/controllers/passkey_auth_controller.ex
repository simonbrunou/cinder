defmodule CinderWeb.PasskeyAuthController do
  @moduledoc """
  "Sign in with a passkey" (#1560), in two POSTs from the log-in page's `PasskeySignIn` hook:

    * `options/2` stores a sign-in challenge (`Cinder.Accounts.Passkeys.sign_in_options/2`) bound
      to the session's identity, keeps its handle in the signed session, and answers the
      `publicKey` options for `navigator.credentials.get` as JSON. It first drops the challenge
      the session's earlier options stored, if any. Each request counts against the
      `:passkey_options` bucket of `Cinder.Accounts.IpRateLimiter`, keyed on the client's network
      (`IpRateLimiter.network_key/1`, an IPv6 /48).
    * `create/2` takes the handle out of the session, counts the attempt against the `:login`
      bucket that password and Jellyfin sign-in share, verifies the assertion
      (`Cinder.Accounts.Passkeys.authenticate/3`) and signs its owner in through
      `CinderWeb.UserAuth.log_in_user/3`, so the role, the remember-me cookie, the return-to
      path, the sudo window and the `/pending` gate behave as for a password sign-in. A blocked
      client's challenge is dropped unverified.

  A signed-in user may sign in again with their own passkey, which refreshes the sudo window. A
  passkey of another user is refused, and the session stays as it was.

  Every refusal of `create/2` is the same flash and a redirect to the log-in page, with no hint
  whether a credential or an account exists, and one `passkey_signin refused` warning
  (`CinderWeb.SignInRefusal`) naming the intent and the reason atom. `options/2` refuses with
  JSON instead and writes no refusal warning: 429 past the client's bucket, 503 when the challenge store
  refuses. Nothing here logs the credential id, the public key, the challenge or the assertion.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.Passkeys
  alias CinderWeb.SignInRefusal
  alias CinderWeb.UserAuth

  @session_key :passkey_challenge

  def options(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    # A session holds one sign-in challenge at a time: new options drop the earlier one.
    Passkeys.discard(get_session(conn, @session_key))

    with :ok <-
           IpRateLimiter.check_and_register(
             :passkey_options,
             IpRateLimiter.network_key(conn.remote_ip)
           ),
         {:ok, %{handle: handle, options: options}} <-
           Passkeys.sign_in_options(CinderWeb.Passkey.relying_party(), current_user_id(conn)) do
      conn
      |> put_session(@session_key, handle)
      |> json(%{publicKey: options})
    else
      :blocked -> conn |> put_status(429) |> json(%{error: "rate_limited"})
      {:error, _reason} -> conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  end

  def create(conn, params) do
    handle = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)
    intent = if current_user_id(conn), do: :reauth, else: :login

    if IpRateLimiter.check_and_register(:login, ip_string(conn)) == :blocked do
      Passkeys.discard(handle)
      refuse(conn, intent, SignInRefusal.refusal(:throttle, :rate_limited))
    else
      verify(conn, intent, handle, Map.get(params, "passkey"))
    end
  end

  defp verify(conn, intent, handle, assertion) do
    case Passkeys.authenticate(handle, current_user_id(conn), assertion) do
      {:ok, user} ->
        remember = if is_map(assertion), do: assertion["remember_me"]

        conn
        |> put_flash(:info, gettext("Welcome back!"))
        |> UserAuth.log_in_user(user, %{"remember_me" => remember})

      {:error, reason} ->
        refuse(conn, intent, SignInRefusal.refusal(:verify, reason))
    end
  end

  defp refuse(conn, intent, refusal) do
    SignInRefusal.warn(:passkey, refusal, intent: intent)

    conn
    |> put_flash(:error, gettext("Passkey sign-in failed. Please try again."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp current_user_id(conn) do
    case conn.assigns.current_scope do
      %{user: %{id: id}} -> id
      _ -> nil
    end
  end

  defp ip_string(conn), do: IpRateLimiter.client_key(conn.remote_ip)
end
