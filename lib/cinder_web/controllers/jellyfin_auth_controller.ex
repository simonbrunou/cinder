defmodule CinderWeb.JellyfinAuthController do
  @moduledoc """
  "Sign in with Jellyfin" — one credential POST against the household's own Jellyfin server
  (`Users/AuthenticateByName`). There is no OAuth round-trip, so unlike `PlexAuthController`
  a single action serves both intents, dispatched on whether the browser is already logged in:

    * `:login` (no current user) — resolves the account via
      `Accounts.login_or_register_jellyfin_user/1` (`jellyfin_user_id` match or create; never an
      email lookup) and logs the resulting user in.
    * `:link` (a current user) — attaches the Jellyfin identity to THAT user's own account via
      `Accounts.link_jellyfin_to_user/2` and never logs anyone in.

  `:link` additionally requires sudo mode, exactly like the Plex link: a merely authenticated
  but stale session (a stolen session/remember-me cookie) must not be able to graft an
  attacker's Jellyfin identity onto the victim's account as a backdoor. `:login` never needs it.

  Attempts go through the same `Cinder.Accounts.IpRateLimiter` buckets as password login
  (`UserSessionController.create/2`): this is the same online-guessing surface, and a
  successful guess here can also *create* an account.

  Every failure path is a generic flash + redirect — never leaking Jellyfin or internal error
  detail — to `/users/log-in` for `:login`, `/users/settings` for `:link`.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.JellyfinAuth

  @ip_bucket :login
  @pair_bucket :login_pair

  def create(conn, %{"jellyfin" => %{"username" => username, "password" => password}})
      when is_binary(username) and is_binary(password) do
    intent = intent_for(conn)

    cond do
      intent == :link and not sudo_fresh?(conn) ->
        require_reauth(conn)

      not JellyfinAuth.configured?() ->
        error_redirect(conn, intent, gettext("Jellyfin sign-in is not configured."))

      throttled?(conn, username) ->
        error_redirect(conn, intent, gettext("Jellyfin sign-in failed. Please try again."))

      true ->
        authenticate(conn, intent, username, password)
    end
  end

  # A forged/malformed POST (missing or non-string fields) fails closed.
  def create(conn, _params) do
    error_redirect(
      conn,
      intent_for(conn),
      gettext("Jellyfin sign-in failed. Please try again.")
    )
  end

  defp authenticate(conn, intent, username, password) do
    case JellyfinAuth.impl().authenticate(username, password) do
      {:ok, account} ->
        resolve(conn, intent, account, username)

      {:error, _reason} ->
        error_redirect(conn, intent, gettext("Jellyfin sign-in failed. Please try again."))
    end
  end

  defp resolve(conn, :login, account, username) do
    case Accounts.login_or_register_jellyfin_user(account) do
      {:ok, user} ->
        # The credentials were proven — don't leave the pair's budget spent.
        IpRateLimiter.clear(@pair_bucket, pair_key(conn, username))
        CinderWeb.UserAuth.log_in_user(conn, user)

      {:error, _reason} ->
        error_redirect(conn, :login, gettext("Jellyfin sign-in failed. Please try again."))
    end
  end

  defp resolve(conn, :link, account, username) do
    case Accounts.link_jellyfin_to_user(current_user(conn), account) do
      {:ok, _user} ->
        IpRateLimiter.clear(@pair_bucket, pair_key(conn, username))

        conn
        |> put_flash(:info, gettext("Your Jellyfin account is now linked."))
        |> redirect(to: ~p"/users/settings")

      {:error, _changeset} ->
        error_redirect(
          conn,
          :link,
          gettext("Could not link your Jellyfin account. Please try again.")
        )
    end
  end

  # Increment-and-check in one atomic step per bucket (not a blocked?-then-register pair), like
  # UserSessionController: an IP-only floor a username-rotating attacker can't evade, plus the
  # {ip, username} guard. `or` short-circuits, so a blocked IP doesn't also spend the pair.
  defp throttled?(conn, username) do
    IpRateLimiter.check_and_register(@ip_bucket, ip_string(conn)) == :blocked or
      IpRateLimiter.check_and_register(@pair_bucket, pair_key(conn, username)) == :blocked
  end

  # Case-insensitive, like the password login's pair key — case-rotating the username must land
  # in the same bucket. `:login_pair` is shared with password login, which keys on
  # `{ip, downcased_email}`, so clearing one budget must never clear the other's. The namespace
  # is a TUPLE, not a `"jellyfin:" <> …` string: an email may legally contain `:`, so a string
  # prefix leaves `jellyfin:someone@example.com` registerable and the two keyspaces still
  # overlapping. An ETS key is any Erlang term, and `{:jellyfin, _}` can never equal a binary.
  defp pair_key(conn, username), do: {ip_string(conn), {:jellyfin, String.downcase(username)}}

  defp ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp intent_for(conn) do
    if current_user(conn), do: :link, else: :login
  end

  defp current_user(conn) do
    conn.assigns.current_scope && conn.assigns.current_scope.user
  end

  # Fail closed: no user, or a user whose session isn't password-fresh, is not sudo mode.
  defp sudo_fresh?(conn) do
    case current_user(conn) do
      nil -> false
      user -> Accounts.sudo_mode?(user)
    end
  end

  defp require_reauth(conn) do
    error_redirect(
      conn,
      :link,
      gettext("Please re-enter your password before linking your Jellyfin account.")
    )
  end

  defp error_redirect(conn, :link, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/settings")
  end

  defp error_redirect(conn, :login, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/log-in")
  end
end
