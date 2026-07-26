defmodule Cinder.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Cinder.Repo

  alias Cinder.Accounts.{User, UserNotifier, UserToken}
  alias Cinder.Audit
  alias Cinder.Audit.AdminAudit
  alias Cinder.Notifier
  alias Cinder.Settings

  @topic "accounts"

  @doc """
  Subscribes to the shared account-lifecycle topic: `{:user_registered, user}` (a new
  account lands `active: false`, awaiting approval — via `register_user/2` or the Plex
  sign-up path) and `{:account_activated, user}` (an admin let a pending account in).
  Broad, like `Catalog`'s `"movies"`/`"series"` topics — a subscriber filters by id itself
  (`PendingApprovalLive` cares only about its own user; `DashboardLive` just re-reads the
  pending count on either event).
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)
  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, msg)

  # Single sudo-mode window, used at every reauth checkpoint: the /users/settings mount, the
  # email/password event rechecks, and Plex link/unlink. Previously the mount used 10 minutes
  # while this default was 20 — finding 7 (2026-07-24 pre-public-exposure audit) unified them
  # onto the shorter, more conservative window.
  @sudo_window_minutes 10

  ## Database getters

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value}, bootstrap_token)
      {:ok, %User{}}

      iex> register_user(%{field: bad_value}, bootstrap_token)
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs, submitted_bootstrap_token \\ nil) do
    Repo.transaction(fn ->
      bootstrap_admin? = count_admins() == 0

      if bootstrap_admin? and not valid_bootstrap_token?(submitted_bootstrap_token) do
        Repo.rollback(:invalid_bootstrap_token)
      end

      role = if bootstrap_admin?, do: :admin, else: :user

      %User{}
      |> User.registration_changeset(attrs, validate_unique: false)
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(:role, role)
      |> Ecto.Changeset.put_change(:active, bootstrap_admin?)
      |> put_default_request_quota(role)
      |> Repo.insert()
      |> case do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> announce_pending_user()
  end

  # Post-commit (outside the transaction, per the house rule that a writer never announces
  # mid-transaction), and only for a user who lands inactive: the admin-facing signal is
  # "someone is waiting to be let in". `create_user/2` makes an already-active user, so it
  # stays silent — the admin just created it themselves.
  defp announce_pending_user({:ok, %User{active: false} = user} = result) do
    broadcast({:user_registered, user})
    Notifier.notify({:user_registered, user})
    result
  end

  defp announce_pending_user(result), do: result

  @doc """
  Resolves a Plex account (`%{id:, email:, username:}`, from `Cinder.Accounts.PlexAuth`) to a
  Cinder user for the UNAUTHENTICATED "Sign in with Plex" flow: an existing `plex_id` match logs
  in (refreshing `plex_username` if it changed); otherwise, once an admin exists, a pending
  `:user`-role account is created and auto-confirmed like `register_user/2`. Plex sign-in never
  creates the first account.

  Plex's reported email is **never** used to look up an existing account here — plex.tv email
  isn't proof of inbox ownership, so treating it as one would let any account with mere watch
  access to the configured server log in as whoever happens to share that email (an
  account-takeover path if that email belongs to an admin). To attach Plex to an existing
  account, see `link_plex_to_user/2` (the authenticated `/users/settings` flow, run by the
  account's own logged-in owner).

  A managed Plex Home account with no email can't be matched or created, so it's rejected with
  `{:error, :no_email}`.
  """
  def login_or_register_plex_user(%{id: plex_id} = account) when is_integer(plex_id) do
    case Repo.get_by(User, plex_id: plex_id) do
      %User{} = user -> refresh_plex_username(user, account)
      nil -> create_plex_user(account)
    end
  end

  # A missing/non-integer id (a malformed plex.tv response) must never fall through to
  # Repo.get_by(User, plex_id: nil) — that compiles to `WHERE plex_id IS NULL` and would
  # match an arbitrary password-only user (or raise MultipleResultsError). Fail closed.
  def login_or_register_plex_user(_account), do: {:error, :invalid_account}

  defp refresh_plex_username(user, account) do
    user
    |> User.plex_changeset(%{plex_username: Map.get(account, :username)})
    |> Repo.update()
  end

  defp create_plex_user(%{email: email}) when email in [nil, ""], do: {:error, :no_email}

  defp create_plex_user(account) do
    if count_admins() == 0 do
      {:error, :admin_required}
    else
      do_create_plex_user(account)
    end
  end

  defp do_create_plex_user(account) do
    password = :crypto.strong_rand_bytes(32) |> Base.encode64()

    %User{}
    |> User.registration_changeset(%{
      email: account.email,
      password: password,
      password_confirmation: password
    })
    |> User.plex_changeset(%{plex_id: account.id, plex_username: Map.get(account, :username)})
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Ecto.Changeset.put_change(:role, :user)
    |> Ecto.Changeset.put_change(:active, false)
    |> put_default_request_quota(:user)
    |> Repo.insert()
    |> announce_pending_user()
  end

  defp put_default_request_quota(changeset, :admin), do: changeset

  defp put_default_request_quota(changeset, :user),
    do: Ecto.Changeset.put_change(changeset, :request_quota, Settings.default_request_quota())

  @doc """
  Attaches a Plex identity to an ALREADY-authenticated user's own account — the `/users/settings`
  link flow. Never logs anyone in (unlike `login_or_register_plex_user/1`).
  `unique_constraint(:plex_id)` surfaces as `{:error, changeset}` when that Plex identity is
  already linked to a different account.
  """
  def link_plex_to_user(%User{} = user, account) do
    user
    |> User.plex_changeset(%{plex_id: account.id, plex_username: Map.get(account, :username)})
    |> Repo.update()
  end

  @doc "Detaches a user's Plex identity (clears `plex_id` and `plex_username`)."
  def unlink_plex_from_user(%User{} = user) do
    user
    |> User.plex_changeset(%{plex_id: nil, plex_username: nil})
    |> Repo.update()
  end

  @doc "Checks the one-time first-user bootstrap credential in constant time."
  def valid_bootstrap_token?(submitted) when is_binary(submitted) do
    expected = Application.get_env(:cinder, :bootstrap_token)

    is_binary(expected) and String.trim(expected) != "" and String.trim(submitted) != "" and
      byte_size(expected) == byte_size(submitted) and
      Plug.Crypto.secure_compare(expected, submitted)
  end

  def valid_bootstrap_token?(_), do: false

  @doc "Counts users with the `:admin` role."
  def count_admins do
    Repo.aggregate(from(u in User, where: u.role == :admin), :count)
  end

  @doc """
  Admin-creates a fully-confirmed user. `:role` (default `:user`) and
  `:confirmed_at` are applied via `put_change` — never castable — while email and
  password are validated by `registration_changeset/2`.
  """
  def create_user(%User{} = actor, attrs) do
    admin_transaction(actor, fn _actor ->
      role = Map.get(attrs, :role, :user)

      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(:role, role)
      |> Ecto.Changeset.put_change(:active, true)
      |> Repo.insert()
      |> case do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Reloads an actor and authorizes their current persisted admin role."
  def fetch_current_admin(%User{id: id}) do
    case Repo.get(User, id) do
      %User{role: :admin} = actor -> {:ok, actor}
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Sets a user's role. Refuses to demote the last admin: the admin count is
  re-checked AFTER the write inside one transaction (a write that would drop the
  count to zero rolls back as `{:error, :last_admin}`). Writes an audit row in
  the same transaction.
  """
  def update_user_role(%User{} = actor, %User{} = target, role) when role in [:admin, :user] do
    actor
    |> admin_transaction(fn actor ->
      revoked_tokens = user_session_tokens(target)

      {:ok, updated} =
        target |> Ecto.Changeset.change(role: role) |> Repo.update()

      if count_admins() == 0 do
        Repo.rollback(:last_admin)
      end

      Audit.log_or_rollback(actor, "update_user_role", updated, %{role: to_string(role)})

      delete_tokens(revoked_tokens)
      {updated, revoked_tokens}
    end)
    |> flatten_revocation_result()
  end

  @doc """
  Activates a pending account. The write and audit row commit together; post-commit (never
  mid-transaction) the `{:account_activated, user}` PubSub broadcast reaches an open tab
  (`PendingApprovalLive`, `DashboardLive`'s pending count) and the matching `Notifier` event
  tells the user out-of-band (an email) that they've been let in — mirroring
  `announce_pending_user/1`.
  """
  def activate_user(%User{} = actor, %User{} = target) do
    actor
    |> admin_transaction(fn actor ->
      case Repo.get(User, target.id) do
        %User{active: false} = pending ->
          {:ok, updated} = pending |> Ecto.Changeset.change(active: true) |> Repo.update()
          Audit.log_or_rollback(actor, "activate_user", updated, %{active: true})
          updated

        _ ->
          Repo.rollback(:not_pending)
      end
    end)
    |> tap_ok(fn user ->
      broadcast({:account_activated, user})
      Notifier.notify({:account_activated, user})
    end)
  end

  @doc "Deletes a pending account through the audited, last-admin-safe user deletion path."
  def delete_pending_user(%User{} = actor, %User{} = target) do
    actor
    |> admin_transaction(fn actor ->
      case Repo.get(User, target.id) do
        %User{active: false} = pending -> do_delete_user(actor, pending)
        _ -> Repo.rollback(:not_pending)
      end
    end)
    |> flatten_revocation_result()
  end

  @doc """
  Admin-edits a user's email directly (no confirmation token round-trip), reusing
  `User.email_changeset/2` for validation. Audited in-transaction.

  The edit form pre-fills the current address, so submitting it unchanged is a
  no-op: when the cast email equals the target's current email, return
  `{:ok, target}` without writing or auditing. A genuinely different email is
  still validated (invalid/format/uniqueness errors return `{:error, changeset}`)
  and a real change still updates + audits in one transaction.
  """
  def admin_update_email(%User{} = actor, %User{} = target, attrs) do
    admin_transaction(actor, fn actor ->
      changeset = User.email_changeset(target, attrs)
      no_change? = Ecto.Changeset.get_change(changeset, :email) == nil

      if no_change? and Ecto.Changeset.get_field(changeset, :email) != nil,
        do: target,
        else: do_admin_update_email(actor, changeset)
    end)
  end

  defp do_admin_update_email(%User{} = actor, changeset) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        # GDPR Art.17: never persist the email value in the audit trail — `entity_id`
        # already identifies whose address changed.
        Audit.log_or_rollback(actor, "admin_update_email", updated, %{})

        updated

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc """
  Admin-resets a user's password directly and expires ALL their tokens (logging
  them out everywhere) via `update_user_and_delete_all_tokens/1`. Audited in the
  same transaction.
  """
  def admin_reset_password(%User{} = actor, %User{} = target, attrs) do
    actor
    |> admin_transaction(fn actor ->
      changeset = User.password_changeset(target, attrs)

      case update_user_and_delete_all_tokens(changeset) do
        {:ok, {user, expired_tokens}} ->
          Audit.log_or_rollback(actor, "admin_reset_password", user, %{})
          {user, expired_tokens}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> flatten_revocation_result()
  end

  @doc """
  Deletes a user. Refuses self-delete and refuses to delete the last admin.
  Both guards are enforced inside one transaction: the user is deleted first,
  then the admin count is re-checked AFTER the delete (post-delete in-transaction
  re-count). A zero admin count rolls back as `{:error, :last_admin}`; a
  self-delete rolls back as `{:error, :self_delete}`. The DB cascades the user's
  requests (`user_id :delete_all`) and nilifies any `approved_by_id` links.
  Audited in the same transaction (no email in the audit `detail` — GDPR Art.17;
  see `do_delete_user/3`).
  """
  def delete_user(%User{} = actor, %User{} = target) do
    actor
    |> admin_transaction(fn actor -> do_delete_user(actor, target) end)
    |> flatten_revocation_result()
  end

  @doc """
  Self-service account deletion (GDPR Art.17): the caller deletes their OWN account after
  confirming their current `password`. Refuses a wrong password (`{:error, :invalid_password}`,
  no delete) and refuses to delete the last admin (`{:error, :last_admin}`), reusing the audited,
  last-admin-safe `do_delete_user/3` path with the user as their own actor. The admin gate in
  `admin_transaction` is deliberately bypassed here — a non-admin must be able to erase their own
  account — and the `:self_delete` guard (which blocks an admin deleting themselves from the admin
  UI) is disabled for this self-service path only. The DB cascade removes the user's session tokens
  and requests; the returned revoked tokens let the caller disconnect open live views.
  """
  def delete_own_account(%User{} = user, password) when is_binary(password) do
    if User.valid_password?(user, password) do
      Repo.transaction(fn ->
        do_delete_user(user, user, action: "delete_own_account", self_service: true)
      end)
      |> flatten_revocation_result()
    else
      {:error, :invalid_password}
    end
  end

  defp do_delete_user(%User{} = actor, %User{} = target, opts \\ []) do
    action = Keyword.get(opts, :action, "delete_user")
    self_service? = Keyword.get(opts, :self_service, false)
    revoked_tokens = user_session_tokens(target)
    {:ok, _} = Repo.delete(target)

    cond do
      count_admins() == 0 ->
        Repo.rollback(:last_admin)

      not self_service? and actor.id == target.id ->
        Repo.rollback(:self_delete)

      true ->
        # GDPR Art.17: redact the erased address from any historical audit rows that target
        # this user, then append the deletion record — which carries no email itself, since
        # `entity_id` already identifies the subject.
        scrub_audit_emails(target.id)

        # A self-delete's only actor IS the just-deleted user, so record it with a nil actor
        # (its actor_id would otherwise dangle against a deleted row) — the same end state
        # actor_id nilifies to for any deleted actor.
        audit_actor = if self_service?, do: nil, else: actor
        Audit.log_or_rollback(audit_actor, action, target, %{cascaded_requests: true})

        {target, revoked_tokens}
    end
  end

  # GDPR Art.17: strip the erased email value from `detail` of every append-only audit row that
  # targets this user (entity_type "User" / entity_id), keeping the rows themselves for
  # accountability but not the address.
  defp scrub_audit_emails(user_id) do
    AdminAudit
    |> where([a], a.entity_type == "User" and a.entity_id == ^user_id)
    |> Repo.all()
    |> Enum.each(fn audit ->
      if Map.has_key?(audit.detail, "email") do
        audit
        |> Ecto.Changeset.change(detail: Map.delete(audit.detail, "email"))
        |> Repo.update!()
      end
    end)
  end

  @doc "All users, ordered by id."
  def list_users, do: Repo.all(from u in User, order_by: [asc: u.id])

  @doc """
  Assembles the user's OWN account data for a GDPR Art.15/20 data export, as a JSON-ready map.
  Includes only fields the user provided or that describe their account — never `hashed_password`
  or any token. Datetimes are ISO-8601 strings.
  """
  def export_user_data(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role,
      locale: user.locale,
      notify_email: user.notify_email,
      plex_username: user.plex_username,
      request_quota: user.request_quota,
      active: user.active,
      confirmed_at: iso(user.confirmed_at),
      inserted_at: iso(user.inserted_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc "Counts accounts awaiting admin approval (`active: false`)."
  def count_pending_accounts, do: Repo.aggregate(from(u in User, where: not u.active), :count)

  @doc """
  Updates a user's concurrent-pending request quota (nil = unlimited). Writes an audit row in
  the same transaction, like every other destructive admin action.
  """
  def update_user_quota(%User{} = actor, %User{} = target, quota) do
    admin_transaction(actor, fn actor ->
      case target |> User.quota_changeset(%{request_quota: quota}) |> Repo.update() do
        {:ok, updated} ->
          Audit.log_or_rollback(actor, "update_user_quota", updated, %{request_quota: quota})
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than #{@sudo_window_minutes} minutes ago (the single sudo-mode window shared by every
  reauth checkpoint — see `@sudo_window_minutes`). The limit can be given as second argument
  in minutes.
  """
  def sudo_mode?(user, minutes \\ -@sudo_window_minutes)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "Returns a changeset for the user's display locale."
  def change_user_locale(user, attrs \\ %{}), do: User.locale_changeset(user, attrs)

  @doc "Updates the user's display locale."
  def update_user_locale(user, attrs) do
    user
    |> User.locale_changeset(attrs)
    |> Repo.update()
  end

  @doc "Updates the user's opt-in for request/availability email notifications."
  def update_user_notify_email(user, attrs) do
    user
    |> User.notify_email_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Cinder.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Cinder.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Atomically replaces one session token and returns its revoked token records."
  def replace_user_session_token(user, old_token) when is_binary(old_token) do
    {new_token, user_token} = UserToken.build_session_token(user)

    Repo.transaction(fn ->
      query =
        from t in UserToken,
          where: t.user_id == ^user.id and t.token == ^old_token and t.context == "session"

      case Repo.one(query) do
        %UserToken{} = old_user_token ->
          {:ok, _} = Repo.delete(old_user_token)
          Repo.insert!(user_token)
          {new_token, [old_user_token]}

        nil ->
          Repo.rollback(:session_revoked)
      end
    end)
    |> flatten_revocation_result()
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  defp admin_transaction(actor, fun) do
    Repo.transaction(fn ->
      case fetch_current_admin(actor) do
        {:ok, current_actor} -> fun.(current_actor)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp flatten_revocation_result({:ok, {value, revoked_tokens}}),
    do: {:ok, value, revoked_tokens}

  defp flatten_revocation_result(result), do: result

  defp user_session_tokens(user) do
    Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "session")
  end

  defp delete_tokens([]), do: :ok

  defp delete_tokens(tokens) do
    Repo.delete_all(from t in UserToken, where: t.id in ^Enum.map(tokens, & &1.id))
    :ok
  end

  defp tap_ok({:ok, value} = res, fun) do
    fun.(value)
    res
  end

  defp tap_ok(other, _fun), do: other
end
