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

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    Repo.transaction(fn ->
      role = if Repo.aggregate(User, :count) == 0, do: :admin, else: :user

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

  @doc "Counts users with the `:admin` role."
  def count_admins do
    Repo.aggregate(from(u in User, where: u.role == :admin), :count)
  end

  @doc """
  Admin-creates a fully-confirmed user. `:role` (default `:user`) and
  `:confirmed_at` are applied via `put_change` — never castable — while email and
  password are validated by `registration_changeset/2`.
  """
  def create_user(attrs) do
    role = Map.get(attrs, :role, :user)

    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Ecto.Changeset.put_change(:role, role)
    |> Repo.insert()
  end

  @doc """
  Sets a user's role. Refuses to demote the last admin: the admin count is
  re-checked AFTER the write inside one transaction (a write that would drop the
  count to zero rolls back as `{:error, :last_admin}`). Writes an audit row in
  the same transaction.
  """
  def update_user_role(%User{} = actor, %User{} = target, role) when role in [:admin, :user] do
    Repo.transaction(fn ->
      {:ok, updated} =
        target |> Ecto.Changeset.change(role: role) |> Repo.update()

      if count_admins() == 0 do
        Repo.rollback(:last_admin)
      end

      Audit.log_or_rollback(actor, "update_user_role", updated, %{role: to_string(role)})

      updated
    end)
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
    changeset = User.email_changeset(target, attrs)
    no_change? = Ecto.Changeset.get_change(changeset, :email) == nil

    if no_change? and Ecto.Changeset.get_field(changeset, :email) != nil do
      {:ok, target}
    else
      Repo.transaction(fn -> do_admin_update_email(actor, changeset) end)
    end
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
    changeset = User.password_changeset(target, attrs)

    Repo.transaction(fn ->
      case update_user_and_delete_all_tokens(changeset) do
        {:ok, {user, _expired}} ->
          Audit.log_or_rollback(actor, "admin_reset_password", user, %{})
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
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
    Repo.transaction(fn -> do_delete_user(actor, target) end)
  end

  defp do_delete_user(%User{} = actor, %User{} = target) do
    email = target.email
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

        target
    end
  end

  @doc "All users, ordered by id."
  def list_users, do: Repo.all(from u in User, order_by: [asc: u.id])

  @doc """
  Updates a user's concurrent-pending request quota (nil = unlimited). Writes an audit row in
  the same transaction, like every other destructive admin action.
  """
  def update_user_quota(%User{} = actor, %User{} = target, quota) do
    Repo.transaction(fn ->
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
end
