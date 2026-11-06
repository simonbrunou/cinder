defmodule CinderWeb.PlexAuthController do
  @moduledoc """
  "Sign in with Plex" (PIN-based OAuth against plex.tv) serves two intents through the same
  `start/2` → plex.tv → `callback/2` round-trip, dispatched on whether the browser is already
  logged in:

    * `:login` (no current user) — resolves the linked account via
      `Accounts.login_or_register_plex_user/1` (plex_id match or create; never an email lookup)
      and logs the resulting user in. An admin is never logged in this way (a relayed PIN approval
      would otherwise yield a sudo-fresh admin session); they use their password.
    * `:link` (a current user) — attaches the Plex identity to THAT user's own account via
      `Accounts.link_plex_to_user/2` and never logs anyone in.

  `:link` additionally requires sudo mode (a password re-entered in the last ~20 minutes, the
  same guard `UserLive.Settings` uses for `update_email`/`update_password`) so a merely
  authenticated but stale session (e.g. a stolen session/remember-me cookie) can't graft an
  attacker's Plex identity onto the victim's account as a backdoor. `:login` never needs it.

  Both intents then stash the plex.tv auth token on that user's row via
  `Accounts.store_plex_token/2` — Cloak-encrypted at rest, never logged or rendered — so the
  opt-in Plex watchlist sync (`Cinder.Requests.WatchlistSync`) has a credential to read that
  account's watchlist with. Storing it is not opting in; the toggle lives in `/users/settings`.

  Every failure path is a generic flash + redirect — never leaking plex.tv or internal error
  detail — to `/users/log-in` for `:login`, `/users/settings` for `:link`. It also writes one
  `plex_signin refused` warning naming the intent, the step that refused and its reason
  (`CinderWeb.SignInRefusal`), so an operator can tell the failing step from the log.

  A refusal that names a user Cinder knows also tells the admins, through
  `Accounts.notify_sign_in_refused/2` (one `{:sign_in_refused, user, step}` notifier event, at
  most one per user per hour):

    * `:login`: a refusal after plex.tv returned the account, when a user has that Plex account
      linked. `:admin_password_required` sends none, since an admin's Plex sign-in is refused by
      design.
    * `:link`: a refusal after the callback's sudo check, naming the signed-in user.

  Nothing is sent for a refusal before `check_pin/1` returned a token (`start/2`, the PIN
  check, an expired session), for the sudo re-auth redirect, or for a `:login` with a Plex
  account nobody has linked.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.PlexAuth
  alias CinderWeb.SignInRefusal

  def start(conn, _params) do
    intent = intent_for(conn)

    cond do
      intent == :link and not sudo_fresh?(conn) ->
        require_reauth(conn)

      PlexAuth.configured?() ->
        start_pin(conn, intent)

      true ->
        refuse(
          conn,
          intent,
          SignInRefusal.refusal(:config, :not_configured),
          gettext("Plex sign-in is not configured.")
        )
    end
  end

  defp start_pin(conn, intent) do
    case PlexAuth.impl().create_pin() do
      {:ok, %{id: id, code: code}} ->
        forward_url = url(~p"/auth/plex/callback")

        conn
        |> put_session(:plex_pin_id, id)
        |> put_session(:plex_intent, intent)
        |> redirect(external: PlexAuth.auth_url(code, forward_url))

      {:error, reason} ->
        refuse(
          conn,
          intent,
          SignInRefusal.refusal(:start_pin, reason),
          gettext("Could not start Plex sign-in. Please try again.")
        )
    end
  end

  def callback(conn, _params) do
    pin_id = get_session(conn, :plex_pin_id)
    intent = get_session(conn, :plex_intent) || intent_for(conn)

    conn
    |> delete_session(:plex_pin_id)
    |> delete_session(:plex_intent)
    |> dispatch_callback(pin_id, intent)
  end

  defp dispatch_callback(conn, nil, intent) do
    refuse(
      conn,
      intent,
      SignInRefusal.refusal(:session, :missing_pin),
      gettext("Plex sign-in session expired. Please try again.")
    )
  end

  defp dispatch_callback(conn, pin_id, intent), do: resolve_pin(conn, pin_id, intent)

  defp resolve_pin(conn, pin_id, intent) do
    case PlexAuth.impl().check_pin(pin_id) do
      {:ok, token} ->
        resolve_account(conn, token, intent)

      {:error, :pending} ->
        refuse(
          conn,
          intent,
          SignInRefusal.refusal(:check_pin, :pending),
          gettext("Plex sign-in was not completed. Please try again.")
        )

      {:error, reason} ->
        refuse(
          conn,
          intent,
          SignInRefusal.refusal(:check_pin, reason),
          gettext("Plex sign-in failed. Please try again.")
        )
    end
  end

  defp resolve_account(conn, token, :login) do
    case SignInRefusal.at(:account, PlexAuth.impl().account(token)) do
      {:ok, account} ->
        log_in_account(conn, token, account)

      {:refused, _step, reason, _fields} = refusal ->
        refuse(conn, :login, refusal, login_failure(reason))
    end
  end

  defp resolve_account(conn, token, :link) do
    case current_user(conn) do
      # The session asked to link, but its user is no longer signed in: there is no account to
      # link to, so the visitor goes back to the log-in page.
      nil ->
        refuse(
          conn,
          :link,
          SignInRefusal.refusal(:session, :logged_out),
          gettext("Plex sign-in failed. Please try again."),
          :login
        )

      user ->
        if Accounts.sudo_mode?(user) do
          link_account(conn, token, user)
        else
          require_reauth(conn)
        end
    end
  end

  # plex.tv returned the account, so a refusal from here on concerns a known Plex identity: when a
  # user has it linked, the admins hear of it (`notify_linked_user/3`).
  defp log_in_account(conn, token, account) do
    with :ok <- authorize_server_access(token, account),
         {:ok, user} <-
           SignInRefusal.at(:account_write, Accounts.login_or_register_plex_user(account)) do
      Accounts.store_plex_token(user, token)
      CinderWeb.UserAuth.log_in_user(conn, user)
    else
      {:refused, step, reason, _fields} = refusal ->
        notify_linked_user(account, step, reason)
        refuse(conn, :login, refusal, login_failure(reason))
    end
  end

  # An admin's Plex sign-in is refused by design, not by a fault, so it sends no notice. A Plex
  # account no user has linked (a stranger) finds nobody.
  defp notify_linked_user(_account, _step, :admin_password_required), do: :ok

  defp notify_linked_user(account, step, _reason) do
    case Accounts.get_user_by_plex_id(plex_id(account)) do
      nil -> :ok
      user -> Accounts.notify_sign_in_refused(user, step)
    end
  end

  # Every refusal here comes after plex.tv returned a token for the signed-in user's own link, so
  # each one tells the admins, naming that user.
  defp link_account(conn, token, user) do
    with {:ok, account} <- SignInRefusal.at(:account, PlexAuth.impl().account(token)),
         :ok <- authorize_server_access(token, account),
         {:ok, linked} <-
           SignInRefusal.at(:account_write, Accounts.link_plex_to_user(user, account)) do
      Accounts.store_plex_token(linked, token)

      conn
      |> put_flash(:info, gettext("Your Plex account is now linked."))
      |> redirect(to: ~p"/users/settings")
    else
      {:refused, step, _reason, _fields} = refusal ->
        Accounts.notify_sign_in_refused(user, step)

        refuse(
          conn,
          :link,
          refusal,
          gettext("Could not link your Plex account. Please try again.")
        )
    end
  end

  # The admin and no-email refusals keep their own flash whichever step returned them, as before
  # the steps were tagged.
  defp login_failure(:admin_password_required),
    do: gettext("Administrators can't sign in with Plex. Sign in with your password instead.")

  defp login_failure(:no_email),
    do: gettext("Your Plex account has no email address; sign in with a password instead.")

  defp login_failure(_reason), do: gettext("Plex sign-in failed. Please try again.")

  # Allow iff the household's configured Plex server's machine id is among the resource
  # ids plex.tv lists for this Plex account (owner or shared user); anyone else is rejected.
  # A refusal logs the account's plex.tv id and how many ids the list held, never the list.
  defp authorize_server_access(token, account) do
    with {:ok, server_id} <-
           SignInRefusal.at(:server_machine_id, PlexAuth.impl().server_machine_id()),
         {:ok, ids} <- SignInRefusal.at(:server_ids, PlexAuth.impl().resource_ids(token)) do
      if server_id in ids,
        do: :ok,
        else:
          SignInRefusal.refusal(:server_access, :forbidden,
            plex_id: plex_id(account),
            resources: length(ids)
          )
    end
  end

  defp plex_id(%{id: id}), do: id
  defp plex_id(_account), do: nil

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
    refuse(
      conn,
      :link,
      SignInRefusal.refusal(:sudo, :reauth_required),
      gettext("Please re-enter your password before linking your Plex account.")
    )
  end

  # Every failure path ends here: one warning line naming the step and the reason, then the flash
  # and the redirect. `back_to` is the intent whose page the visitor returns to, when it differs
  # from the intent logged.
  defp refuse(conn, intent, refusal, message, back_to \\ nil) do
    SignInRefusal.warn(:plex, refusal, intent: intent)
    error_redirect(conn, back_to || intent, message)
  end

  defp error_redirect(conn, :link, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/settings")
  end

  defp error_redirect(conn, :login, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/log-in")
  end
end
