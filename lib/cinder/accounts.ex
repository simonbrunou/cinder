defmodule Cinder.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Cinder.Repo

  alias Cinder.Accounts.{User, UserNotifier, UserToken}
  alias Cinder.Audit

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
      first_user? = Repo.aggregate(User, :count) == 0

      if first_user? and not valid_bootstrap_token?(submitted_bootstrap_token) do
        Repo.rollback(:invalid_bootstrap_token)
      end

      role = if first_user?, do: :admin, else: :user

      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(:role, role)
      |> Repo.insert()
      |> case do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Resolves a Plex account (`%{id:, email:, username:}`, from `Cinder.Accounts.PlexAuth`) to a
  Cinder user for the UNAUTHENTICATED "Sign in with Plex" flow: an existing `plex_id` match logs
  in (refreshing `plex_username` if it changed); otherwise a new `:user`-role account is created,
  auto-confirmed like `register_user/2` but never admin and never gated by the bootstrap token
  (Plex sign-in is not a first-user path).

  Plex's reported email is **never** used to look up an existing account here — plex.tv email
  isn't proof of inbox ownership, so treating it as one would let any account with mere watch
  access to the configured server log in as whoever happens to share that email (an
  account-takeover path if that email belongs to an admin). To attach Plex to an existing
  account, see `link_plex_to_user/2` (the authenticated `/users/settings` flow, run by the
  account's own logged-in owner).

  A managed Plex Home account with no email can't be matched or created, so it's rejected with
  `{:error, :no_email}`.
  """
  def login_or_register_plex_user(%{id: plex_id} = account) do
    case Repo.get_by(User, plex_id: plex_id) do
      %User{} = user -> refresh_plex_username(user, account)
      nil -> create_plex_user(account)
    end
  end

  defp refresh_plex_username(user, account) do
    user
    |> User.plex_changeset(%{plex_username: Map.get(account, :username)})
    |> Repo.update()
  end

  defp create_plex_user(%{email: email}) when email in [nil, ""], do: {:error, :no_email}

  defp create_plex_user(account) do
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
    |> Repo.insert()
  end

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
        Audit.log_or_rollback(actor, "admin_update_email", updated, %{email: updated.email})

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
  Audited in the same transaction; the email is captured before the delete so
  the audit `detail` can record it.
  """
  def delete_user(%User{} = actor, %User{} = target) do
    actor
    |> admin_transaction(fn actor -> do_delete_user(actor, target) end)
    |> flatten_revocation_result()
  end

  defp do_delete_user(%User{} = actor, %User{} = target) do
    email = target.email
    revoked_tokens = user_session_tokens(target)
    {:ok, _} = Repo.delete(target)

    cond do
      count_admins() == 0 ->
        Repo.rollback(:last_admin)

      actor.id == target.id ->
        Repo.rollback(:self_delete)

      true ->
        Audit.log_or_rollback(actor, "delete_user", target, %{
          email: email,
          cascaded_requests: true
        })

        {target, revoked_tokens}
    end
  end

  @doc "All users, ordered by id."
  def list_users, do: Repo.all(from u in User, order_by: [asc: u.id])

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
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

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
end
