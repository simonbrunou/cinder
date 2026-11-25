defmodule Cinder.Indexers do
  @moduledoc """
  The configured indexers: the one writer of `configured_indexers` and the reads Native search
  and the Test use. It never writes Native's runtime state.

  ## Writes

  Each write takes the actor (a `%User{}` or nil) for the audit row. An edit or a toggle also
  takes the `lock_version` the caller's form opened with: a save opened on an older version
  returns `{:error, changeset}` with an error on `lock_version` (tagged `stale: true`), and a save
  that changes nothing still runs that check. A save or delete of an id that no longer exists
  returns `{:error, :not_found}`.

  Secret inputs arrive apart from the plain attrs, as one map (`Cinder.Indexers.Secrets`). An
  edit that changes no secret leaves `secrets_ciphertext` byte for byte as it was. When the
  stored secrets do not decrypt, a save that sets or clears every secret replaces the ciphertext
  (with none once no secret is left), any other secret save is refused on `secrets`, and an edit
  of other fields keeps the ciphertext.

  Two counters tell later readers what an edit changed:

    * `credentials_version` rises by one on a base URL change or a secret change.
    * `config_version` rises by one on a base URL, API path, settings, FlareSolverr or secret
      change. A name, priority or enable edit leaves both.

  A delete and an edit that changes the base URL or a secret write one `Cinder.Audit` row inside
  their transaction, naming the changed fields and never a value. A create, a toggle and any
  other edit write none.

  ## Reads

    * `searchable/0`: every enabled configured indexer whose secrets decrypt, with them.
    * `fetch_with_secrets/1`: one configured indexer, enabled or not, with its secrets.
    * `list/0`: every configured indexer, without secret values, each marked by
      `secrets_readable`.
  """

  import Ecto.Query

  alias Cinder.Accounts.User
  alias Cinder.Audit
  alias Cinder.Indexers.{ConfiguredIndexer, Secrets}
  alias Cinder.Repo

  @type actor :: User.t() | nil
  @type write_result :: {:ok, ConfiguredIndexer.t()} | {:error, Ecto.Changeset.t()}

  # The edits each counter follows.
  @credentials_fields [:base_url]
  @config_fields [:base_url, :api_path, :settings, :flaresolverr]

  @doc "Creates a configured indexer from plain `attrs` and secret `secrets` inputs."
  @spec create(actor(), map(), map()) :: write_result()
  def create(_actor, attrs, secrets \\ %{}) do
    changeset = ConfiguredIndexer.create_changeset(attrs)
    type = Ecto.Changeset.get_field(changeset, :type)

    with {:ok, values} <- create_secrets(changeset, type, secrets) do
      Repo.transact(fn -> insert_with_secrets(changeset, values) end)
    end
  end

  defp create_secrets(changeset, type, secrets) do
    case Secrets.merge({:ok, %{}}, secrets, ConfiguredIndexer.secret_fields(type)) do
      :unchanged -> {:ok, %{}}
      {:changed, values, _fields} -> {:ok, values}
      {:error, tag} -> {:error, secrets_error(changeset, tag, :insert)}
    end
  end

  # The ciphertext names the row's id, so it is sealed once the insert has given the row one. A
  # write that can carry the ciphertext runs with `log: false`, as `Cinder.Accounts.Passkeys`
  # does, so a debug log never holds it.
  defp insert_with_secrets(changeset, values) do
    with {:ok, row} <- changeset |> Repo.insert() |> tag_constraint_errors() do
      row
      |> Ecto.Changeset.change(secrets_ciphertext: Secrets.seal(row.id, values))
      |> Repo.update(log: false)
    end
  end

  @doc """
  Edits the configured indexer `id` with plain `attrs` and secret `secrets` inputs, checked
  against the `lock_version` the caller opened it with.
  """
  @spec update(actor(), pos_integer(), integer(), map(), map()) ::
          write_result() | {:error, :not_found}
  def update(actor, id, lock_version, attrs, secrets \\ %{}) when is_integer(lock_version) do
    Repo.transact(fn ->
      with {:ok, row} <- fetch_row(id),
           {:ok, changeset, audit_detail} <- edit(row, lock_version, attrs, secrets),
           {:ok, updated} <- save(changeset) do
        audit_edit(actor, updated, audit_detail)
        {:ok, updated}
      end
    end)
  end

  @doc "Turns the configured indexer `id` on or off; an edit that moves neither counter."
  @spec set_enabled(actor(), pos_integer(), integer(), boolean()) ::
          write_result() | {:error, :not_found}
  def set_enabled(actor, id, lock_version, enabled) when is_boolean(enabled),
    do: update(actor, id, lock_version, %{enabled: enabled})

  @doc """
  Deletes the configured indexer `id`, audited in the same transaction: `{:error, changeset}` is
  the audit row's refusal, which rolls the delete back.
  """
  @spec delete(actor(), pos_integer()) :: :ok | {:error, :not_found | Ecto.Changeset.t()}
  def delete(actor, id) do
    Repo.transact(fn ->
      case Repo.delete_all(from(c in ConfiguredIndexer, where: c.id == ^id)) do
        {1, _} ->
          Audit.log_or_rollback(actor, "delete_configured_indexer", {"ConfiguredIndexer", id})
          {:ok, :deleted}

        {0, _} ->
          {:error, :not_found}
      end
    end)
    |> case do
      {:ok, :deleted} -> :ok
      error -> error
    end
  end

  defp fetch_row(id) do
    case Repo.get(ConfiguredIndexer, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # Builds the edit's changeset on the row as it is now. A caller's lock_version that differs from
  # the row's is refused here, because Ecto skips the optimistic lock's check on a changeset that
  # fails validation; the immediate transaction keeps another write out until the save.
  defp edit(row, lock_version, attrs, secrets) do
    changeset = ConfiguredIndexer.edit_changeset(row, attrs)

    case Secrets.merge(Secrets.open(row), secrets, ConfiguredIndexer.secret_fields(row.type)) do
      _merge when row.lock_version != lock_version ->
        {:error, stale_error(changeset)}

      {:error, tag} ->
        {:error, secrets_error(changeset, tag, :update)}

      :unchanged ->
        {:ok, bump_counters(changeset, []), audit_detail(changeset, [])}

      {:changed, values, secret_fields} ->
        changeset
        |> put_ciphertext(row.id, values)
        |> bump_counters(secret_fields)
        |> then(&{:ok, &1, audit_detail(changeset, secret_fields)})
    end
  end

  # A changeset that already fails validation gets no new ciphertext, so its error holds none;
  # `save/1` drops it from one the database refuses.
  defp put_ciphertext(%Ecto.Changeset{valid?: false} = changeset, _id, _values), do: changeset

  defp put_ciphertext(changeset, id, values),
    do: Ecto.Changeset.put_change(changeset, :secrets_ciphertext, Secrets.seal(id, values))

  defp bump_counters(changeset, secret_fields) do
    changed = Map.keys(changeset.changes)
    secret? = secret_fields != []

    changeset
    |> bump(:credentials_version, secret? or Enum.any?(@credentials_fields, &(&1 in changed)))
    |> bump(:config_version, secret? or Enum.any?(@config_fields, &(&1 in changed)))
  end

  defp bump(changeset, _counter, false), do: changeset

  defp bump(changeset, counter, true),
    do: Ecto.Changeset.put_change(changeset, counter, Map.fetch!(changeset.data, counter) + 1)

  # Field names only, never values; nil when the edit is not audited.
  defp audit_detail(changeset, secret_fields) do
    if Map.has_key?(changeset.changes, :base_url) or secret_fields != [] do
      %{
        fields: changeset.changes |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
        secrets: secret_fields
      }
    end
  end

  # A no-op save still runs the lock_version check, so it is forced. "is invalid" is the stale
  # error's message because errors.pot already holds it; the `stale: true` tag names the rule.
  defp save(changeset) do
    changeset
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(
      force: true,
      stale_error_field: :lock_version,
      stale_error_message: "is invalid",
      log: false
    )
    |> without_ciphertext()
    |> tag_constraint_errors()
  end

  # A save the database refuses, such as on a taken name, returns without the new ciphertext.
  defp without_ciphertext({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, Ecto.Changeset.delete_change(changeset, :secrets_ciphertext)}

  defp without_ciphertext(ok), do: ok

  defp stale_error(changeset) do
    %{
      Ecto.Changeset.add_error(changeset, :lock_version, "is invalid", stale: true)
      | action: :update
    }
  end

  # The database's refusals carry Ecto's constraint metadata; this adds the `validation:` tag the
  # write path's own refusals carry.
  defp tag_constraint_errors({:error, %Ecto.Changeset{} = changeset}) do
    {:error, %{changeset | errors: Enum.map(changeset.errors, &tag_constraint_error/1)}}
  end

  defp tag_constraint_errors(ok), do: ok

  defp tag_constraint_error({field, {message, opts}} = error) do
    case {field, opts[:constraint]} do
      {:name, :unique} -> {field, {message, opts ++ [validation: :unique_name]}}
      {:priority, :check} -> {field, {message, opts ++ [validation: :priority_range]}}
      _other -> error
    end
  end

  defp audit_edit(_actor, _row, nil), do: :ok

  defp audit_edit(actor, row, detail),
    do: Audit.log_or_rollback(actor, "update_configured_indexer_access", row, detail)

  # The action a form reads to show the changeset's errors, as Repo.insert/update would set it.
  defp secrets_error(changeset, tag, action) do
    validation = if tag == :unreadable, do: :secrets_unreadable, else: :secret_fields

    changeset =
      Ecto.Changeset.add_error(changeset, :secrets, "is invalid", validation: validation)

    %{changeset | action: action}
  end

  @doc """
  Every enabled configured indexer whose secrets decrypt, with them in `secrets`, ordered by
  priority, then id. A row whose secrets do not decrypt is left out.
  """
  @spec searchable() :: [ConfiguredIndexer.t()]
  def searchable do
    ConfiguredIndexer
    |> where([c], c.enabled)
    |> ordered()
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      case with_secrets(row) do
        {:ok, row} -> [row]
        {:error, :undecryptable_secrets} -> []
      end
    end)
  end

  @doc """
  The configured indexer `id`, enabled or not, with its secrets in `secrets`:
  `{:error, :not_found}` for a missing row, `{:error, :undecryptable_secrets}` for secrets that do
  not decrypt.
  """
  @spec fetch_with_secrets(pos_integer()) ::
          {:ok, ConfiguredIndexer.t()} | {:error, :not_found | :undecryptable_secrets}
  def fetch_with_secrets(id) do
    with {:ok, row} <- fetch_row(id), do: with_secrets(row)
  end

  @doc """
  Every configured indexer without secret values, ordered by priority, then id, each with
  `secrets_readable` set to whether its secrets decrypt.
  """
  @spec list() :: [ConfiguredIndexer.t()]
  def list do
    ConfiguredIndexer
    |> ordered()
    |> Repo.all()
    |> Enum.map(&%{&1 | secrets_readable: Secrets.open(&1) != :unreadable})
  end

  defp ordered(query), do: order_by(query, [c], asc: c.priority, asc: c.id)

  defp with_secrets(row) do
    case Secrets.open(row) do
      {:ok, values} -> {:ok, %{row | secrets: values, secrets_readable: true}}
      :unreadable -> {:error, :undecryptable_secrets}
    end
  end
end
