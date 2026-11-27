defmodule Cinder.Indexers do
  @moduledoc """
  The configured indexers: the one writer of `configured_indexers` and the reads Native search
  and the Test use. It never writes Native's runtime state.

  ## Writes

  Each write takes the actor (a `%User{}` or nil) for the audit row. An edit or a toggle also
  takes the `lock_version` the caller's form opened with: a save opened on an older version
  returns `{:error, changeset}` with an error on `lock_version` (tagged `stale: true`), and a save
  that changes nothing still runs that check. A save or delete of an id that no longer exists
  returns `{:error, :not_found}`. A refusal of the base URL, the API path or the settings,
  whether `ConfiguredIndexer`'s checks or a Cardigann copy's refused it, returns a changeset
  without that field's typed value (`ConfiguredIndexer.drop_refused/1`).

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

  An edit of a Cardigann indexer whose `definition` names another file is a Switch (#1907;
  #1616 rule 7): it moves the indexer onto the mirror's copy of the file that replaces its own,
  rebuilds its settings and secrets for that copy (`CardigannSettings.switch/5`), raises both
  counters, writes one audit row naming the changed fields, the changed secret names and the two
  file names, and moves the pin, all in one transaction. `switch_hosts/4` reads the hosts it
  would send credentials to that the indexer does not send them to today, from the same
  builder, and the save is refused when that list changed since the form showed it
  (`hosts_digest/1`). Unlike an edit, a Switch always writes a new `secrets_ciphertext` from the
  secrets it builds. When the stored secrets do not decrypt, it needs every secret the new copy
  declares set or cleared, and a Switch to a copy that declares none writes no ciphertext.

  The Prowlarr import (`Cinder.Indexers.ProwlarrImport`) creates its rows through
  `import_batch/2`, one transaction with one audit row, each row linked to its Prowlarr indexer
  by `prowlarr_indexer_id` (`create_imported/4`, the only write of that column).

  ## Reads

    * `searchable/0`: every enabled configured indexer whose secrets decrypt, with them.
    * `fetch_with_secrets/1`: one configured indexer, enabled or not, with its secrets.
    * `fetch_for_edit/1`: one configured indexer without secret values, with the names of the
      secret fields it holds.
    * `list/0`: every configured indexer, without secret values, each marked by
      `secrets_readable`.
    * `prowlarr_links/0`: each linked configured indexer's id with its Prowlarr indexer id,
      which the import's already-imported check and the linked-pair block read use.

  ## The source switch

  `check_source_switch/2` is the rule a switch of the `indexer_source` setting to Built-in
  passes: some enabled indexer passes the gate. `switch_source/1` applies it and writes the
  setting alone.
  """

  import Ecto.Changeset, only: [validate_change: 3]
  import Ecto.Query

  alias Cinder.Accounts.User
  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerState
  alias Cinder.Audit
  alias Cinder.Indexers.{CardigannSettings, ConfiguredIndexer, Definitions, Secrets}
  alias Cinder.Indexers.Definitions.CredentialHosts
  alias Cinder.Repo
  alias Cinder.Settings
  alias Cinder.Settings.Registry

  # The indexer source setting, found by its overlay target like the overlay's own writers: its
  # key, its option values and the value whose module is Native (Built-in).
  @source_definition Registry.one!(target: {:writer, :indexer_source})
  @source_key @source_definition.key
  {:indexer_source, source_spec} = @source_definition.shape
  @source_values Enum.map(source_spec.options, & &1.value)
  @native_source Enum.find(source_spec.options, &(&1.module == Native)).value

  @type actor :: User.t() | nil
  @type write_result :: {:ok, ConfiguredIndexer.t()} | {:error, Ecto.Changeset.t()}

  # The edits each counter follows.
  @credentials_fields [:base_url]
  @config_fields [:base_url, :api_path, :settings, :flaresolverr]

  @doc "Creates a configured indexer from plain `attrs` and secret `secrets` inputs."
  @spec create(actor(), map(), map()) :: write_result()
  def create(_actor, attrs, secrets \\ %{}),
    do: attrs |> ConfiguredIndexer.create_changeset() |> create_typed(attrs, secrets)

  @doc """
  Creates a configured indexer for the Prowlarr import (`Cinder.Indexers.ProwlarrImport`), as
  `create/3` does, linked to the Prowlarr indexer `prowlarr_indexer_id`: the only write of
  `prowlarr_indexer_id`. A link another row holds is refused on `prowlarr_indexer_id`, tagged
  `validation: :unique_link`. It runs inside the import's transaction.
  """
  @spec create_imported(actor(), map(), map(), pos_integer()) :: write_result()
  def create_imported(_actor, attrs, secrets, prowlarr_indexer_id)
      when is_integer(prowlarr_indexer_id) do
    attrs
    |> ConfiguredIndexer.create_changeset()
    |> ConfiguredIndexer.link_changeset(prowlarr_indexer_id)
    |> create_typed(attrs, secrets)
  end

  @doc """
  Creates the Prowlarr import's configured indexers (`Cinder.Indexers.ProwlarrImport`) in one
  transaction with one `Cinder.Audit` row, `"import_prowlarr_indexers"`, naming their count and
  Prowlarr ids. Each entry is `%{prowlarr_id, attrs, secrets}`, created with
  `create_imported/4` in the order given.

  Inside the transaction it first checks the links and names again: an entry whose Prowlarr id
  a configured indexer is already linked to gives `:already_imported`, and one whose trimmed
  name another configured indexer holds gives `:name_taken`. Any such entry refuses the whole
  batch with `{:error, {:rows, codes_by_prowlarr_id}}` before any insert. An insert that is
  refused rolls the batch back with `{:error, {:rows, %{prowlarr_id => codes}}}`:
  `:name_conflict` and `:link_conflict` for the unique indexes, `{field, validation}` for any
  other check. A refused audit row rolls it back with `{:error, changeset}`.
  """
  @spec import_batch(actor(), [%{prowlarr_id: pos_integer(), attrs: map(), secrets: map()}]) ::
          {:ok, [ConfiguredIndexer.t()]}
          | {:error, {:rows, %{pos_integer() => [term()]}} | Ecto.Changeset.t()}
  def import_batch(actor, entries) when is_list(entries) do
    Repo.transact(fn ->
      linked = MapSet.new(prowlarr_links(), &elem(&1, 1))
      names = MapSet.new(Repo.all(from(c in ConfiguredIndexer, select: c.name)))

      held =
        for entry <- entries,
            codes = held_codes(entry, linked, names),
            codes != [],
            into: %{},
            do: {entry.prowlarr_id, codes}

      if held == %{}, do: insert_batch(actor, entries), else: {:error, {:rows, held}}
    end)
  end

  defp held_codes(entry, linked, names) do
    name = entry.attrs |> Map.get("name", Map.get(entry.attrs, :name)) |> trimmed()

    if(entry.prowlarr_id in linked, do: [:already_imported], else: []) ++
      if name in names, do: [:name_taken], else: []
  end

  defp trimmed(name) when is_binary(name), do: String.trim(name)
  defp trimmed(name), do: name

  defp insert_batch(actor, entries) do
    created =
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, rows} ->
        case create_imported(actor, entry.attrs, entry.secrets, entry.prowlarr_id) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          {:error, changeset} -> {:halt, {:error, entry.prowlarr_id, changeset}}
        end
      end)

    case created do
      {:ok, rows} ->
        rows = Enum.reverse(rows)

        Audit.log_or_rollback(actor, "import_prowlarr_indexers", {"ConfiguredIndexer", nil}, %{
          count: length(rows),
          prowlarr_indexer_ids: Enum.map(rows, & &1.prowlarr_indexer_id)
        })

        {:ok, rows}

      {:error, prowlarr_id, changeset} ->
        Repo.rollback({:rows, %{prowlarr_id => insert_codes(changeset)}})
    end
  end

  defp insert_codes(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {_message, opts}} ->
      case Keyword.get(opts, :validation) do
        :unique_name -> :name_conflict
        :unique_link -> :link_conflict
        validation -> {field, validation}
      end
    end)
    |> Enum.uniq()
  end

  defp create_typed(changeset, attrs, secrets),
    do: create_typed(changeset, Ecto.Changeset.get_field(changeset, :type), attrs, secrets)

  defp create_typed(changeset, :cardigann, attrs, secrets),
    do: Repo.transact(fn -> create_cardigann(changeset, blob_sha(attrs), secrets) end)

  defp create_typed(changeset, type, _attrs, secrets) do
    with {:ok, values} <- create_secrets(changeset, type, secrets) do
      Repo.transact(fn -> insert_with_secrets(changeset, values) end)
    end
  end

  defp blob_sha(attrs), do: attr(attrs, :definition_blob_sha)

  # A Cardigann create pins the copy the form rendered, then checks the base URL and the
  # settings against it, all inside one transaction.
  defp create_cardigann(%Ecto.Changeset{valid?: false} = changeset, _blob_sha, _secrets),
    do: {:error, %{changeset | action: :insert}}

  defp create_cardigann(changeset, blob_sha, secrets) do
    name = Ecto.Changeset.get_field(changeset, :definition)
    input = Ecto.Changeset.get_field(changeset, :settings)

    with {:ok, pinned} <- pin(changeset, name, blob_sha, :insert),
         :ok <- check_link(changeset, pinned.definition, :insert),
         {:ok, plain, values} <- cardigann_values(changeset, pinned.definition, input, secrets),
         {:ok, row} <-
           changeset
           |> Ecto.Changeset.put_change(:settings, plain)
           |> insert_with_secrets(values) do
      :ok = Definitions.attach_pin(row.id, pinned)
      {:ok, row}
    end
  end

  defp pin(changeset, name, blob_sha, action) do
    case Definitions.pin(name, blob_sha) do
      {:ok, pinned} ->
        {:ok, pinned}

      {:error, reason} ->
        {:error, refuse(changeset, :definition, pin_validation(reason), action)}
    end
  end

  defp pin_validation(:not_in_mirror), do: :definition_not_in_mirror
  defp pin_validation(:fails), do: :definition_fails

  # The base URL must be one of the copy's links; Ecto runs the check only when the base URL
  # changes, so an edit of other fields keeps a URL the running copy now lists as legacy.
  defp check_link(changeset, definition, action) do
    changeset =
      validate_change(changeset, :base_url, fn field, url ->
        if url in (definition.links || []),
          do: [],
          else: [{field, {"is invalid", validation: :base_url_links}}]
      end)

    if changeset.valid?,
      do: :ok,
      else: {:error, %{ConfiguredIndexer.drop_refused(changeset) | action: action}}
  end

  defp cardigann_values(changeset, definition, input, secrets) do
    case CardigannSettings.create(definition, input || %{}, secrets) do
      {:ok, plain, values} -> {:ok, plain, values}
      {:error, field, validation} -> {:error, refuse(changeset, field, validation, :insert)}
    end
  end

  defp refuse(changeset, field, validation, action) do
    changeset = Ecto.Changeset.add_error(changeset, field, "is invalid", validation: validation)
    %{ConfiguredIndexer.drop_refused(changeset) | action: action}
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
    if switch?(row, attrs) do
      switch(row, lock_version, attrs, secrets)
    else
      changeset = ConfiguredIndexer.edit_changeset(row, Map.drop(attrs, plain_settings_keys(row)))

      cond do
        row.lock_version != lock_version -> {:error, stale_error(changeset)}
        not rendered_copy?(row, attrs) -> {:error, definition_changed(changeset)}
        true -> edit_fields(row, changeset, attrs, secrets)
      end
    end
  end

  # A Cardigann edit form carries the hash of the copy it rendered; a save once the indexer runs
  # another copy, as after an apply or an Accept, is refused (#1676; #1620 point 4). An edit
  # that names no hash, as a toggle, is not checked.
  defp rendered_copy?(%ConfiguredIndexer{type: :cardigann} = row, attrs) do
    case blob_sha(attrs) do
      nil -> true
      sha -> Definitions.running_blob_sha(row.id) == sha
    end
  end

  defp rendered_copy?(_row, _attrs), do: true

  defp definition_changed(changeset),
    do: refuse(changeset, :definition, :definition_changed, :update)

  # --- Switch to %{name} (#1907; #1616 rule 7) ---

  # A Switch names another definition file in `definition`; any other change of it stays
  # refused as `:fixed_at_create`.
  defp switch?(%ConfiguredIndexer{type: :cardigann, definition: current}, attrs) do
    case attr(attrs, :definition) do
      name when is_binary(name) -> name != current
      _other -> false
    end
  end

  defp switch?(_row, _attrs), do: false

  # An attr the caller may key by atom or by string, as a form sends it.
  defp attr(attrs, key), do: Map.get(attrs, key, attrs[Atom.to_string(key)])

  # The save of a Switch: what `switch_build/4` builds, once the host list it gives matches the
  # one the form showed (`switch_hosts_digest`). Both counters rise, one audit row names the
  # changed fields and secrets and the two file names, and the pin moves to the new copy in the
  # same transaction (`Definitions.switch_pin/2`).
  defp switch(row, lock_version, attrs, secrets) do
    with {:ok, built} <- switch_build(row, lock_version, attrs, secrets),
         :ok <- check_hosts_digest(row, built, attrs) do
      detail = switch_detail(row, built)

      changeset =
        built.changeset
        |> put_ciphertext(row.id, built.values)
        |> bump(:credentials_version, true)
        |> bump(:config_version, true)

      {:ok, changeset, {:switch, detail, built.pinned}}
    end
  end

  # Names only, as an edit's row has them: the base URL counts when it differs from the stored
  # one (the build casts it over none), and a secret when its value differs or, for stored
  # secrets that do not decrypt, when the Switch sets it.
  defp switch_detail(row, built) do
    fields =
      for {field, value} <- built.changeset.changes,
          field != :base_url or value != row.base_url,
          do: to_string(field)

    secrets =
      case built.stored do
        :unreadable ->
          Map.keys(built.values)

        stored ->
          stored
          |> Map.merge(built.values)
          |> Map.keys()
          |> Enum.filter(&(stored[&1] != built.values[&1]))
      end

    %{
      fields: Enum.sort(fields),
      secrets: Enum.sort(secrets),
      from_definition: row.definition,
      to_definition: built.changeset.changes.definition
    }
  end

  defp check_hosts_digest(row, built, attrs) do
    if attr(attrs, :switch_hosts_digest) == hosts_digest(shown_hosts(host_pairs(row, built))),
      do: :ok,
      else: {:error, refuse(built.changeset, :definition, :switch_hosts_changed, :update)}
  end

  # Everything a Switch of `row` writes, from the plain `attrs` and the secret input `secrets`
  # as the form sends them: the changeset with the new `definition`, its `settings` and the
  # form's fields, the new copy `Definitions.pin/2` checked (`pinned`), and the plain settings
  # and secret values (`plain`, `values`) `CardigannSettings.switch/5` builds over the row's
  # stored ones. The save and the host list (`switch_host_pairs/4`) both call it, so the list
  # reads the values the save writes.
  defp switch_build(row, lock_version, attrs, secrets) do
    new = attr(attrs, :definition)
    plain_attrs = Map.drop(attrs, [:settings, "settings", :definition, "definition"])

    # Cast over no base URL, so the form's one counts as a change and `check_link/3` checks it
    # against the new copy's links even when it is the stored one.
    changeset = ConfiguredIndexer.edit_changeset(%{row | base_url: nil}, plain_attrs)
    input = attr(attrs, :settings) || %{}
    stored = stored_secrets(row)

    with :ok <- switch_allowed(row, changeset, lock_version, new),
         {:ok, pinned} <- pin(changeset, new, blob_sha(attrs), :update),
         :ok <- check_link(changeset, pinned.definition, :update),
         {:ok, plain, values} <-
           switch_values(changeset, row, pinned.definition, stored, input, secrets) do
      changeset =
        changeset
        |> Ecto.Changeset.put_change(:definition, new)
        |> Ecto.Changeset.put_change(:settings, plain)

      {:ok, %{changeset: changeset, pinned: pinned, plain: plain, values: values, stored: stored}}
    end
  end

  # Stored secrets that do not decrypt go on as `:unreadable`, so the input must then set or
  # clear every secret of the new copy, as an edit's "re-enter every secret" rule does.
  defp stored_secrets(row) do
    case Secrets.open(row) do
      {:ok, values} -> values
      :unreadable -> :unreadable
    end
  end

  defp switch_allowed(row, changeset, lock_version, new) do
    cond do
      row.lock_version != lock_version ->
        {:error, stale_error(changeset)}

      Definitions.name_status(row.definition) != {:replaced_by, new} ->
        {:error, refuse(changeset, :definition, :fixed_at_create, :update)}

      true ->
        :ok
    end
  end

  defp switch_values(changeset, row, definition, stored, input, secrets) do
    case CardigannSettings.switch(definition, row.settings || %{}, stored, input, secrets) do
      {:ok, plain, values} -> {:ok, plain, values}
      {:error, field, validation} -> {:error, refuse(changeset, field, validation, :update)}
    end
  end

  @doc """
  The credential hosts a Switch of the Cardigann configured indexer `id` would send credentials
  to that it does not send them to today (#1907; #1616 rule 7), for the Switch form, from the
  `lock_version`, plain `attrs` and secret input `secrets` its save would send. Each host shows
  in the form `switch_host_pairs/4` gives it, sorted, once.
  """
  @spec switch_hosts(pos_integer(), integer(), map(), map()) ::
          {:ok, [CredentialHosts.host()]} | {:error, switch_refusal()}
  def switch_hosts(id, lock_version, attrs, secrets) do
    with {:ok, pairs} <- switch_host_pairs(id, lock_version, attrs, secrets),
         do: {:ok, shown_hosts(pairs)}
  end

  @typedoc """
  Why a Switch's host list is not read: the indexer is gone or is no Cardigann indexer
  (`:not_found`), or the save would refuse the input with `{field, validation}`, as
  `{:lock_version, :stale}` or `{:secrets, :secrets_unreadable}`.
  """
  @type switch_refusal :: :not_found | {atom(), atom()}

  @doc """
  The hosts of `switch_hosts/4` as `{host, shown}` pairs, sorted. A page shows only `shown`:
  `host` can hold a secret's value.

  - The new side is each pair `CredentialHosts.shown/3` gives for the values the save writes
    (`switch_build/4`, the save's own builder): the new copy, the base URL its changeset holds,
    and its plain settings and secret values, each secret key standing as its template.
  - The old side is the set of hosts the indexer's search and grab send a credential to today,
    read through the adapter as a grab reads the row (`fetch_with_secrets/1`, so a disabled row
    counts, and `Cinder.Acquisition.Indexer.Cardigann.copy/1`). It is empty when the row sends
    no credential anywhere: its secrets do not decrypt, its running copy does not run, or it
    holds no secret the adapter sends (the request's `secrets` is empty: none non-blank,
    declared by the running copy and other than its default).
  - A pair is left out only when the old side holds its `host` as text. An unknown host
    (`{:unknown, raw}`) always stays: its raw text holds no filled value, so the same text on
    both sides can still be two hosts.

  The new side is not emptied when the values it reads hold no secret the adapter would send,
  so such a list names every host of the new copy. The refusals are `switch_hosts/4`'s: the
  list is never read for an input the save would refuse.
  """
  @spec switch_host_pairs(pos_integer(), integer(), map(), map()) ::
          {:ok, [{CredentialHosts.host(), CredentialHosts.host()}]} | {:error, switch_refusal()}
  def switch_host_pairs(id, lock_version, attrs, secrets) do
    with {:ok, %ConfiguredIndexer{type: :cardigann} = row} <- fetch_row(id),
         {:switch, true} <- {:switch, switch?(row, attrs)},
         {:ok, built} <- switch_build(row, lock_version, attrs, secrets) do
      {:ok, host_pairs(row, built)}
    else
      {:switch, false} -> {:error, {:definition, :fixed_at_create}}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, switch_refusal(changeset)}
      _not_cardigann -> {:error, :not_found}
    end
  end

  defp switch_refusal(%Ecto.Changeset{errors: [{field, {_message, opts}} | _]}),
    do: {field, opts[:validation] || if(opts[:stale], do: :stale, else: :invalid)}

  defp host_pairs(row, built) do
    stored = %{
      stored_url: Ecto.Changeset.get_field(built.changeset, :base_url),
      settings: Map.merge(built.plain, built.values)
    }

    old = sent_today(row.id)

    built.pinned.definition
    |> CredentialHosts.shown(stored, Map.keys(built.values))
    |> Enum.reject(fn {host, _shown} -> MapSet.member?(old, host) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The hosts the indexer sends a credential to today, as the adapter's request for it reads
  # them at Native's clock, the time a search renders it at, those named as text: none when the
  # request sends no secret.
  defp sent_today(id) do
    with {:ok, indexer} <- fetch_with_secrets(id),
         {:ok, %{request: request}} <- Cardigann.copy(indexer),
         %{secrets: [_ | _], credential_hosts: hosts} <- request.(%{}, Native.now()) do
      MapSet.filter(hosts, &is_binary/1)
    else
      _sends_nowhere -> MapSet.new()
    end
  end

  defp shown_hosts(pairs), do: pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

  @doc """
  The digest of a Switch's host list as `switch_hosts/4` gives it. The Switch form sends it as
  `switch_hosts_digest`, and the save is refused on `definition` as `:switch_hosts_changed`
  when the list it reads at the save differs, so no host the form did not show gets a
  credential.
  """
  @spec hosts_digest([CredentialHosts.host()]) :: String.t()
  def hosts_digest(hosts),
    do: :sha256 |> :crypto.hash(:erlang.term_to_binary(hosts)) |> Base.encode16(case: :lower)

  # A Cardigann edit's settings merge into the stored ones (`edit_cardigann/4`), so the cast
  # never sees them.
  defp plain_settings_keys(%ConfiguredIndexer{type: :cardigann}), do: [:settings, "settings"]
  defp plain_settings_keys(_row), do: []

  defp edit_fields(%ConfiguredIndexer{type: :cardigann} = row, changeset, attrs, secrets) do
    input = attr(attrs, :settings) || %{}

    if input == %{} and secrets == %{} and not Map.has_key?(changeset.changes, :base_url),
      do: finish_edit(changeset, row, :unchanged),
      else: edit_cardigann(row, changeset, input, secrets)
  end

  defp edit_fields(row, changeset, _attrs, secrets) do
    case Secrets.merge(Secrets.open(row), secrets, ConfiguredIndexer.secret_fields(row.type)) do
      {:error, tag} -> {:error, secrets_error(changeset, tag, :update)}
      merge -> finish_edit(changeset, row, merge)
    end
  end

  # A Cardigann edit that touches the base URL, a setting or a secret checks it against the
  # running copy, never the mirror's.
  defp edit_cardigann(row, changeset, input, secrets) do
    stored = Secrets.open(row)
    secret_keys = MapSet.new(if match?({:ok, _}, stored), do: Map.keys(elem(stored, 1)), else: [])

    with {:ok, definition} <- running_definition(row, changeset),
         :ok <- check_link(changeset, definition, :update),
         {:ok, plain} <- edit_plain(changeset, definition, row.settings, secret_keys, input) do
      fields = CardigannSettings.secret_fields(definition, plain, stored)
      changeset = Ecto.Changeset.put_change(changeset, :settings, plain)

      case CardigannSettings.edit_secrets(definition, stored, secrets, fields) do
        {:error, field, validation} -> {:error, refuse(changeset, field, validation, :update)}
        merge -> finish_edit(changeset, row, merge)
      end
    end
  end

  defp running_definition(row, changeset) do
    case Definitions.running_definition(row.id) do
      {:ok, definition} -> {:ok, definition}
      {:error, _reason} -> {:error, refuse(changeset, :definition, :definition_fails, :update)}
    end
  end

  defp edit_plain(changeset, definition, stored, secret_keys, input) do
    case CardigannSettings.edit_plain(definition, stored, secret_keys, input) do
      {:ok, plain} -> {:ok, plain}
      {:error, field, validation} -> {:error, refuse(changeset, field, validation, :update)}
    end
  end

  defp finish_edit(changeset, row, merge) do
    case merge do
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
      {:prowlarr_indexer_id, :unique} -> {field, {message, opts ++ [validation: :unique_link]}}
      _other -> error
    end
  end

  defp audit_edit(_actor, _row, nil), do: :ok

  # A Switch moves the pin once the row is saved, and its audit row names the fields and secrets,
  # never a value, and the two definition file names.
  defp audit_edit(actor, row, {:switch, detail, pinned}) do
    :ok = Definitions.switch_pin(row.id, pinned)

    Audit.log_or_rollback(
      actor,
      "switch_configured_indexer_definition",
      row,
      Map.put(detail, :to_copy, pinned.blob_sha)
    )
  end

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

  @doc """
  The configured indexer `id` for an edit form, without secret values: `{:ok, row, stored}`,
  where `stored` lists the names of the secret fields it holds, or is `:unreadable` when its
  secrets do not decrypt; `{:error, :not_found}` for a missing row.
  """
  @spec fetch_for_edit(pos_integer()) ::
          {:ok, ConfiguredIndexer.t(), [String.t()] | :unreadable} | {:error, :not_found}
  def fetch_for_edit(id) do
    with {:ok, row} <- fetch_row(id) do
      case Secrets.open(row) do
        {:ok, values} -> {:ok, %{row | secrets_readable: true}, Enum.sort(Map.keys(values))}
        :unreadable -> {:ok, %{row | secrets_readable: false}, :unreadable}
      end
    end
  end

  @doc """
  Every Cardigann configured indexer, enabled or not, by id, each with its stored values: its
  plain `settings` and its decrypted secrets, or `:undecryptable` when they do not decrypt.
  `Cinder.Indexers.Definitions` reads it inside its write transactions.
  """
  @spec cardigann_indexers() :: [
          {ConfiguredIndexer.t(), %{plain: map(), secrets: Secrets.values()} | :undecryptable}
        ]
  def cardigann_indexers do
    ConfiguredIndexer
    |> where([c], c.type == :cardigann)
    |> order_by([c], asc: c.id)
    |> Repo.all()
    |> Enum.map(fn row ->
      case Secrets.open(row) do
        {:ok, values} -> {row, %{plain: row.settings, secrets: values}}
        :unreadable -> {row, :undecryptable}
      end
    end)
  end

  @doc """
  The links the Prowlarr import wrote: `{configured indexer id, Prowlarr indexer id}` for each
  configured indexer that has one, ordered by configured indexer id.
  """
  @spec prowlarr_links() :: [{pos_integer(), pos_integer()}]
  def prowlarr_links do
    Repo.all(
      from c in ConfiguredIndexer,
        where: not is_nil(c.prowlarr_indexer_id),
        order_by: [asc: c.id],
        select: {c.id, c.prowlarr_indexer_id}
    )
  end

  @doc """
  Raises `config_version` and `lock_version` of the configured indexer `id` by one: Accept of a
  held definition update (`Cinder.Indexers.Definitions.accept/3`) changes what the indexer runs,
  and a form opened before it must reload. Runs inside the caller's transaction.
  """
  @spec bump_config_version(pos_integer()) :: :ok | {:error, :not_found}
  def bump_config_version(id) do
    case Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^id),
           inc: [config_version: 1, lock_version: 1]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  @doc """
  Whether a Newznab or Torznab configured indexer with `base_url` and `api_path` is searched
  through Prowlarr at `prowlarr_url`: its API path is `/<digits>/api`, Prowlarr's per-indexer
  endpoint, and its base URL equals `prowlarr_url`, each with its trailing slashes removed. A nil
  or blank `prowlarr_url`, or one that is only slashes, answers false. The settings form shows
  what Prowlarr does to such an indexer's results (#1661); the Prowlarr import is to create its
  rows in this shape (#1673).
  """
  @spec through_prowlarr?(String.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def through_prowlarr?(base_url, api_path, prowlarr_url)
      when is_binary(base_url) and is_binary(api_path) and is_binary(prowlarr_url) do
    prowlarr = String.trim_trailing(prowlarr_url, "/")

    String.trim(prowlarr) != "" and Regex.match?(~r/\A\/[0-9]+\/api\z/, api_path) and
      String.trim_trailing(base_url, "/") == prowlarr
  end

  def through_prowlarr?(_base_url, _api_path, _prowlarr_url), do: false

  @doc """
  The rule for a switch of the indexer source (#1662, #1622 point 5): `:ok`, or
  `{:error, :no_working_indexer}` for a `requested` source of `"native"` (Built-in) while
  `current` is another source and `IndexerState.passes_gate?/1` fails, so no enabled indexer is
  usable or in a limit backoff. A request that keeps Built-in, or names any other value, nil
  included, answers `:ok`: the setting's shape refuses a value that is no option.

  `current` defaults to `Cinder.Settings.indexer_source/0`, the source the `/settings` form
  showed: the stored row, else the bootstrap choice. `/settings` calls this on every save, before
  `Cinder.Settings.save_form/1`, which does not apply the rule, since `/setup` saves through it
  too. It writes nothing and answers a code, never text.
  """
  @spec check_source_switch(term(), String.t()) :: :ok | {:error, :no_working_indexer}
  def check_source_switch(requested, current \\ Settings.indexer_source())

  def check_source_switch(@native_source, current) when current != @native_source do
    if IndexerState.passes_gate?(), do: :ok, else: {:error, :no_working_indexer}
  end

  def check_source_switch(_requested, _current), do: :ok

  @doc """
  Writes the indexer source `requested` alone, as `"prowlarr"` or `"native"`, once
  `check_source_switch/2` allows it against the source `/settings` shows: for a switch made
  outside the form, such as over `rpc` (#1688). A value that is no option, matched exactly,
  answers `{:error, :unknown_indexer_source}`, and a refused switch `{:error, :no_working_indexer}`;
  neither writes. An allowed request writes its row through `Cinder.Settings.put/2`, also when
  that source is already stored.
  """
  @spec switch_source(term()) :: :ok | {:error, :no_working_indexer | :unknown_indexer_source}
  def switch_source(requested) when requested in @source_values do
    with :ok <- check_source_switch(requested), do: Settings.put(@source_key, requested)
  end

  def switch_source(_requested), do: {:error, :unknown_indexer_source}

  defp ordered(query), do: order_by(query, [c], asc: c.priority, asc: c.id)

  defp with_secrets(row) do
    case Secrets.open(row) do
      {:ok, values} -> {:ok, %{row | secrets: values, secrets_readable: true}}
      :unreadable -> {:error, :undecryptable_secrets}
    end
  end
end
