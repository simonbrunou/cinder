defmodule CinderWeb.PlexAuthController do
  @moduledoc """
  "Sign in with Plex" (PIN-based OAuth against plex.tv) serves two intents through the same
  `start/2` → plex.tv → `callback/2` round-trip, dispatched on whether the browser is already
  logged in:

    * `:login` (no current user) — resolves the linked account via
      `Accounts.login_or_register_plex_user/1` (plex_id match or create; never an email lookup)
      and logs the resulting user in.
    * `:link` (a current user) — attaches the Plex identity to THAT user's own account via
      `Accounts.link_plex_to_user/2` and never logs anyone in.

  `:link` additionally requires sudo mode (a password re-entered in the last ~20 minutes, the
  same guard `UserLive.Settings` uses for `update_email`/`update_password`) so a merely
  authenticated but stale session (e.g. a stolen session/remember-me cookie) can't graft an
  attacker's Plex identity onto the victim's account as a backdoor. `:login` never needs it.

  Every failure path is a generic flash + redirect — never leaking plex.tv or internal error
  detail — to `/users/log-in` for `:login`, `/users/settings` for `:link`.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Accounts.PlexAuth

  def start(conn, _params) do
    intent = intent_for(conn)

    cond do
      intent == :link and not sudo_fresh?(conn) ->
        require_reauth(conn)

      PlexAuth.configured?() ->
        start_pin(conn, intent)

      true ->
        error_redirect(conn, intent, gettext("Plex sign-in is not configured."))
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

      {:error, _reason} ->
        error_redirect(conn, intent, gettext("Could not start Plex sign-in. Please try again."))
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
    error_redirect(conn, intent, gettext("Plex sign-in session expired. Please try again."))
  end

  defp dispatch_callback(conn, pin_id, intent), do: resolve_pin(conn, pin_id, intent)

  defp resolve_pin(conn, pin_id, intent) do
    case PlexAuth.impl().check_pin(pin_id) do
      {:ok, token} ->
        resolve_account(conn, token, intent)

      {:error, :pending} ->
        error_redirect(conn, intent, gettext("Plex sign-in was not completed. Please try again."))

      {:error, _reason} ->
        error_redirect(conn, intent, gettext("Plex sign-in failed. Please try again."))
    end
  end

  defp resolve_account(conn, token, :login) do
    with {:ok, account} <- PlexAuth.impl().account(token),
         :ok <- authorize_server_access(token),
         {:ok, user} <- Accounts.login_or_register_plex_user(account) do
      CinderWeb.UserAuth.log_in_user(conn, user)
    else
      {:error, :no_email} ->
        error_redirect(
          conn,
          :login,
          gettext("Your Plex account has no email address; sign in with a password instead.")
        )

      {:error, _reason} ->
        error_redirect(conn, :login, gettext("Plex sign-in failed. Please try again."))
    end
  end

  defp resolve_account(conn, token, :link) do
    case current_user(conn) do
      nil ->
        error_redirect(conn, :login, gettext("Plex sign-in failed. Please try again."))

      user ->
        if Accounts.sudo_mode?(user) do
          link_account(conn, token, user)
        else
          require_reauth(conn)
        end
    end
  end

  defp link_account(conn, token, user) do
    with {:ok, account} <- PlexAuth.impl().account(token),
         :ok <- authorize_server_access(token),
         {:ok, _user} <- Accounts.link_plex_to_user(user, account) do
      conn
      |> put_flash(:info, gettext("Your Plex account is now linked."))
      |> redirect(to: ~p"/users/settings")
    else
      _ ->
        error_redirect(
          conn,
          :link,
          gettext("Could not link your Plex account. Please try again.")
        )
    end
  end

  # Allow iff the household's configured Plex server is among the servers this
  # Plex account can reach (owner or shared user); anyone else is rejected.
  defp authorize_server_access(token) do
    with {:ok, server_id} <- PlexAuth.impl().server_machine_id(),
         {:ok, ids} <- PlexAuth.impl().server_ids(token) do
      if server_id in ids, do: :ok, else: {:error, :forbidden}
    end
  end

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
      gettext("Please re-enter your password before linking your Plex account.")
    )
  end

  defp error_redirect(conn, :link, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/settings")
  end

  defp error_redirect(conn, :login, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/log-in")
  end
end
