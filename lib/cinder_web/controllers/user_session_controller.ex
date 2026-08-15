defmodule CinderWeb.UserSessionController do
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.IpRateLimiter
  alias CinderWeb.UserAuth

  # Buckets in the shared IpRateLimiter table: the IP-only floor below (kept distinct from
  # :registration's bucket) and the {ip, email} brute-force guard.
  @ip_bucket :login
  @pair_bucket :login_pair

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # email + password login
  defp create(
         conn,
         %{"user" => %{"email" => email, "password" => password} = user_params},
         info
       )
       when is_binary(email) and is_binary(password) do
    ip = ip_string(conn)

    cond do
      # A per-IP floor beneath the {ip, email} limiter: rotating the email on every request
      # evades that limiter (it's keyed on the pair), but not this one. Increment-and-check in
      # one atomic step (not a blocked?-then-register pair) so a concurrent burst can't sail
      # past the gate before the counters land. Same generic response as bad credentials — no
      # oracle either way — and it counts every attempt, so it bounds bcrypt cost per IP.
      IpRateLimiter.check_and_register(@ip_bucket, ip) == :blocked ->
        invalid_credentials(conn, email)

      # An exhausted {ip, email} pair gets the SAME generic response as bad credentials,
      # so the limiter can't be used as an enumeration or lockout oracle. Counting every
      # attempt (not just failures) changes nothing observable: a successful login clears
      # the pair right below, and the fixed window never extends on increment.
      IpRateLimiter.check_and_register(@pair_bucket, pair_key(ip, email)) == :blocked ->
        invalid_credentials(conn, email)

      user = Accounts.get_user_by_email_and_password(email, password) ->
        IpRateLimiter.clear(@pair_bucket, pair_key(ip, email))

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      true ->
        # The failed attempt was already counted by check_and_register at the gate above.
        invalid_credentials(conn, email)
    end
  end

  defp create(conn, _params, _info) do
    IpRateLimiter.check_and_register(@ip_bucket, ip_string(conn))
    invalid_credentials(conn, "")
  end

  # The pair guard keys case-insensitively — an attacker case-rotating the email must land
  # in the same bucket.
  defp pair_key(ip, email), do: {ip, String.downcase(email)}

  defp invalid_credentials(conn, email) do
    # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
    conn
    |> put_flash(:error, gettext("Invalid email or password"))
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  defp ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user

    # Sudo recheck: this POST can arrive after the sudo window lapses (a stale settings tab, or a
    # direct request), so redirect to reauth rather than crashing on a `true = ...` match (finding
    # 7 — mirrors with_sudo_mode/2 in UserLive.Settings).
    if Accounts.sudo_mode?(user) do
      {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      # This authenticated, sudo-gated path pipes into the rate-limited create/3 below AFTER
      # committing the new password and expiring every session token — a blocked {ip, email}
      # pair (or a blocked IP-only bucket) here would lock the user out of the password they
      # just set. Clear both: the user has already proven possession of the account.
      IpRateLimiter.clear(@pair_bucket, pair_key(ip_string(conn), user.email))
      IpRateLimiter.clear(@ip_bucket, ip_string(conn))

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(params, gettext("Password updated successfully!"))
    else
      conn
      |> put_flash(:error, gettext("You must re-authenticate to access this page."))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end

  # Self-service account deletion (GDPR Art.17). Sudo-rechecked like update_password/2 above —
  # this POST can arrive after the sudo window lapses — then delegates to
  # Accounts.delete_own_account/2, which re-verifies the password server-side and refuses the
  # last admin. On success the session is cleared via log_out_user/1 (the DB tokens are already
  # cascade-deleted).
  def delete_account(conn, %{"delete_account" => %{"password" => password}}) do
    user = conn.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.delete_own_account(user, password) do
        {:ok, _user, _revoked_tokens} ->
          conn
          |> put_flash(:info, gettext("Your account has been permanently deleted."))
          |> UserAuth.log_out_user()

        {:error, :invalid_password} ->
          conn
          |> put_flash(:error, gettext("The password you entered is incorrect."))
          |> redirect(to: ~p"/users/settings")

        {:error, :last_admin} ->
          conn
          |> put_flash(
            :error,
            gettext(
              "You are the last admin. Grant another user admin before deleting your account."
            )
          )
          |> redirect(to: ~p"/users/settings")
      end
    else
      conn
      |> put_flash(:error, gettext("You must re-authenticate to access this page."))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # A forged/malformed POST without the password field fails closed.
  def delete_account(conn, _params) do
    conn
    |> put_flash(:error, gettext("The password you entered is incorrect."))
    |> redirect(to: ~p"/users/settings")
  end
end
