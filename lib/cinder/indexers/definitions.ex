defmodule Cinder.Indexers.Definitions do
  @moduledoc """
  The mirror of the upstream indexer definitions (#1667, part of #1610; rules 7 to 12 of #1616's
  resolution): the one writer of `indexer_definition_copies`, `indexer_definition_load_results`,
  `indexer_definition_entries` and `indexer_definition_set`, and the reads over them.

  ## Applying a set

  `apply_set/2` takes the `Cinder.Indexers.Definitions.Set` that
  `Cinder.Indexers.Definitions.Source.fetch/1` answers. The engine's version is the schema
  version `Cinder.Indexers.Definitions.Loader.fingerprint/0` declares.

  1. A `MIN_VERSION` above the engine's version refuses the answer as `:cinder_too_old`.
  2. The guard counts the distinct file names with a file in a folder from `MIN_VERSION` up to
     the engine's version: the names that get a mirror copy once the answer applies. A name only
     in folders above the engine or below `MIN_VERSION` does not count. The stored set's `count`
     and the `count` of a `:shrank` or `:first_too_small` refusal are that number. With no stored
     set, an answer under 100 names is refused as `:first_too_small`. With a stored set, an
     answer under 90% of its count is refused as `:shrank` by N%, N rounded down. An answer at
     the commit `accept_smaller_set/1` took passes this guard, until an apply succeeds or a
     refusal at another commit follows.
  3. The mirror's copy of each file name is the one in the highest folder from `MIN_VERSION` up
     to the engine's version. A folder above the engine is never read: the highest of them that
     holds a copy other than the mirror's is recorded by number, and a name only such folders
     hold is recorded with the lowest of them. These folders come from the files present, never
     from `MAX_VERSION`.
  4. The load check runs on each mirror copy whose blob hash has no result under the current
     fingerprint, before the write transaction, at most `ParserWorker.max_check_workers/0` at a
     time.
  5. One transaction stores the copies and results, swaps the mirror's entries and the set row,
     and deletes the copies no entry uses and the results no copy uses or that another
     fingerprint wrote.

  A refusal writes only the set row's state and keeps every stored copy, result and entry.

  ## The boot re-check

  `stale_copies/0` lists the stored copies with no result under the current fingerprint;
  `check_copies/2` runs the load check on them, and `store_results/1` stores the answers in one
  transaction, with no network call. `Cinder.Indexers.Definitions.Updater` runs them at boot.

  ## Reads

  - `set_state/1`: never loaded, loaded, the last refusal, or an update failing for more than
    72 hours, read with the update job's run row (`Cinder.Indexers.Definitions.UpdateRun`).
  - `loaded/0`: the set the mirror holds.
  - `name_status/1`: what the mirror says about one file name.
  - `picker/0`: the mirror's names with their display fields and load results.
  - `import_copy/1`: one file name's mirror copy with its load result, for the Prowlarr import.

  ## Configured indexers' copies (#1668)

  Each Cardigann configured indexer has one row in `indexer_definition_pins`
  (`Cinder.Indexers.Definitions.Pin`): the copy it runs, the copy held back from it and the
  hold's reason.

  - `Cinder.Indexers`' create calls `pin/2` for the copy the form rendered and `attach_pin/2`
    once the row exists, in its own transaction.
  - The apply's transaction and `store_results/1`'s re-read every Cardigann configured indexer
    through `Cinder.Indexers.cardigann_indexers/0` and decide each one's copies with
    `Cinder.Indexers.Definitions.Hold.decide/1`; a row deleted since the load checks is not
    read. An apply never writes `configured_indexers`. When it moves the effective base URL of
    an indexer with no credentials, the same transaction writes one audit row with a nil actor.
  - `accept/3` makes a held copy the running copy; `held_hosts/1` lists the hosts it adds.
  - A copy stays while the mirror or a pin's running or held copy uses it.
  - `indexer_codes/0` gives each pinned indexer's definition code for
    `Cinder.Acquisition.IndexerSource.Native.IndexerState`.

  Every state and status is a code; the web layer owns their texts (#1676).
  """

  import Ecto.Query

  require Logger

  alias Cinder.Indexers.Definitions.{
    Copy,
    Entry,
    LoadCheck,
    Loader,
    LoadResult,
    Set,
    StoredSet,
    UpdateRun
  }

  alias Cinder.Audit
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.Definitions.{CredentialHosts, Hold, Pin}
  alias Cinder.Indexers.ParserWorker
  alias Cinder.Repo

  @set_id 1
  @first_floor 100
  @shrink_floor_percent 90
  # How long after the last successful update run a run of failures shows as "update failing".
  @failing_after_s 72 * 3600
  # A check waits for a node slot, then runs under ParserWorker.check_deadline_ms/0. A check past
  # this is dropped with no result, and the next boot re-check runs it again.
  @check_timeout_ms 300_000

  # The current fingerprint's results.
  defmacrop current_fingerprint(result) do
    quote do
      unquote(result).schema_version == ^Loader.fingerprint().schema_version and
        unquote(result).revision == ^Loader.fingerprint().revision
    end
  end

  @type result :: :loads | {:not_supported, [term()]} | {:fails, Loader.reason()}
  @typedoc "The set the mirror holds."
  @type loaded :: %{count: non_neg_integer(), commit: String.t(), loaded_at: DateTime.t()}
  @typedoc "A refused answer; `loaded` is the set the mirror still holds, nil before any load."
  @type refusal ::
          {:cinder_too_old,
           %{commit: String.t(), min_version: non_neg_integer(), loaded: loaded() | nil}}
          | {:shrank,
             %{
               percent: non_neg_integer(),
               commit: String.t(),
               count: non_neg_integer(),
               loaded: loaded() | nil
             }}
          | {:first_too_small,
             %{commit: String.t(), count: non_neg_integer(), loaded: loaded() | nil}}
  @type state ::
          {:never_loaded, %{error: term()}}
          | {:loaded, loaded()}
          | {:update_failing, %{since: DateTime.t(), error: term(), loaded: loaded()}}
          | refusal()
  @type name_status ::
          :never_loaded
          | :in_mirror
          | {:replaced_by, String.t()}
          | {:needs_newer_cinder, pos_integer()}
          | :removed_upstream
  @type copy :: %{blob_sha: String.t(), bytes: binary()}

  @doc "How long `check_copies/2` waits for one check by default, in milliseconds."
  @spec check_timeout_ms() :: pos_integer()
  def check_timeout_ms, do: @check_timeout_ms

  @doc """
  Applies an upstream answer. Returns the new set state, or the refusal, which `set_state/1`
  then reads too. `{:error, changeset}` is a refused audit row of a base URL move, which rolls
  the whole apply back.

  `opts`: `:check`, the load check run on each copy's bytes (`LoadCheck.check/2` with no options
  unless set; a test seam), and `:timeout_ms`, which `check_copies/2` reads.
  """
  @spec apply_set(Set.t(), keyword()) :: {:ok, state()} | {:error, refusal() | Ecto.Changeset.t()}
  def apply_set(%Set{} = set, opts \\ []) do
    stored = Repo.get(StoredSet, @set_id)
    min = set.versions.min

    if min > engine_version() do
      refuse(stored, set, :cinder_too_old, refused_versions: set.versions.values)
    else
      files = counted_files(set)
      count = mirror_count(files)

      case guard(stored, set.commit, count) do
        :ok -> load(set, files, count, opts)
        {:refuse, state, fields} -> refuse(stored, set, state, [refused_count: count] ++ fields)
      end
    end
  end

  @doc """
  The files of `set` the engine reads: those in folders from `MIN_VERSION` up to the engine's
  version, each as `{folder number, file}`. The canary checks these.
  """
  @spec engine_files(Set.t()) :: [{non_neg_integer(), Set.DefinitionFile.t()}]
  def engine_files(%Set{} = set) do
    engine = engine_version()
    for %{folder: number} = file <- counted_files(set), number <= engine, do: {number, file.file}
  end

  @doc "The schema version the engine declares: the highest folder it reads."
  @spec engine_version() :: pos_integer()
  def engine_version, do: Loader.fingerprint().schema_version

  # Each file in a folder at or above MIN_VERSION, with its folder's number.
  defp counted_files(set) do
    for file <- set.files,
        number = folder_number(file.folder),
        is_integer(number) and number >= set.versions.min,
        do: %{folder: number, name: file.name, file: file}
  end

  # The names that get a mirror copy once the answer applies: those of `counted_files/1` with a
  # file in a folder up to the engine's version. The guard and the stored set's count both read
  # this.
  defp mirror_count(files) do
    ceiling = engine_version()
    files |> Enum.filter(&(&1.folder <= ceiling)) |> Enum.uniq_by(& &1.name) |> length()
  end

  # `Cinder.Indexers.Definitions.Archive` keeps every `v<digits>` folder. Only the plain spelling
  # of a number up to 999,999 counts: `v012` would name a second folder 12, and a longer number
  # would overflow SQLite's integer.
  defp folder_number(folder) do
    case Regex.run(~r/\Av(0|[1-9][0-9]{0,5})\z/, folder) do
      [_folder, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp guard(%StoredSet{accepted_commit: commit}, commit, _count) when is_binary(commit), do: :ok
  defp guard(%StoredSet{commit: nil}, _commit, count), do: first_floor_guard(count)
  defp guard(nil, _commit, count), do: first_floor_guard(count)

  defp guard(%StoredSet{count: stored_count}, _commit, count),
    do: shrink_guard(stored_count, count)

  defp first_floor_guard(count) when count < @first_floor, do: {:refuse, :first_too_small, []}
  defp first_floor_guard(_count), do: :ok

  defp shrink_guard(stored_count, count)
       when count * 100 < stored_count * @shrink_floor_percent,
       do: {:refuse, :shrank, shrink_percent: div((stored_count - count) * 100, stored_count)}

  defp shrink_guard(_stored_count, _count), do: :ok

  # Writes the refusal into the set row, keeping the stored set's own fields. A refusal at another
  # commit than the accepted one drops that acceptance.
  defp refuse(stored, set, state, fields) do
    accepted = if stored && stored.accepted_commit == set.commit, do: set.commit

    changes =
      Keyword.merge(
        [
          state: state,
          refused_commit: set.commit,
          refused_count: nil,
          shrink_percent: nil,
          refused_versions: nil,
          accepted_commit: accepted
        ],
        fields
      )

    row =
      Repo.insert!(struct(StoredSet, [id: @set_id] ++ changes),
        on_conflict: [set: changes],
        conflict_target: :id,
        returning: true
      )

    {:error, state_of(row)}
  end

  defp load(set, files, count, opts) do
    entries = files |> Enum.group_by(& &1.name) |> Enum.map(&plan_entry/1)
    copies = for %{copy: %{} = copy} <- entries, do: copy
    known = current_result_shas(Enum.map(copies, & &1.blob_sha))

    results =
      copies
      |> Enum.reject(&MapSet.member?(known, &1.blob_sha))
      |> Enum.uniq_by(& &1.blob_sha)
      |> check_copies(opts)

    Repo.transact(fn -> swap_set(set, count, copies, results, entries) end)
  end

  # The mirror's copy of one name, and what folders above the engine hold of it.
  defp plan_entry({name, files}) do
    engine = engine_version()
    {readable, above} = Enum.split_with(files, &(&1.folder <= engine))

    case Enum.max_by(readable, & &1.folder, fn -> nil end) do
      nil ->
        %{name: name, copy: nil, newer_folder: nil, needs_version: min_folder(above)}

      %{folder: folder, file: file} ->
        newer = for %{file: other} = f <- above, other.blob_sha != file.blob_sha, do: f.folder

        %{
          name: name,
          copy: %{blob_sha: file.blob_sha, folder: folder, name: name, bytes: file.bytes},
          newer_folder: Enum.max(newer, fn -> nil end),
          needs_version: nil
        }
    end
  end

  defp min_folder(files), do: files |> Enum.map(& &1.folder) |> Enum.min()

  defp current_result_shas(shas) do
    from(r in LoadResult,
      where: r.blob_sha in ^shas and current_fingerprint(r),
      select: r.blob_sha
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The one write of an applied set, the configured indexers' copies included.
  defp swap_set(set, count, copies, results, entries) do
    %{schema_version: version, revision: revision} = Loader.fingerprint()
    insert_copies(copies)
    insert_results(results)

    replaces =
      from(r in LoadResult,
        where: r.blob_sha in ^Enum.map(copies, & &1.blob_sha) and current_fingerprint(r),
        select: {r.blob_sha, r.replaces}
      )
      |> Repo.all()
      |> Map.new()

    Repo.delete_all(Entry)

    entries
    |> Enum.map(&entry_row(&1, replaces))
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Entry, &1))

    loaded_at = DateTime.utc_now(:second)

    row = [
      commit: set.commit,
      versions: set.versions.values,
      count: count,
      loaded_at: loaded_at,
      state: :loaded,
      refused_commit: nil,
      refused_count: nil,
      shrink_percent: nil,
      refused_versions: nil,
      accepted_commit: nil
    ]

    Repo.insert!(struct(StoredSet, [id: @set_id] ++ row),
      on_conflict: [set: row],
      conflict_target: :id
    )

    decide_pins()
    delete_unused(version, revision)
    {:ok, {:loaded, %{count: count, commit: set.commit, loaded_at: loaded_at}}}
  end

  defp entry_row(%{copy: nil} = entry, _replaces) do
    %{
      name: entry.name,
      blob_sha: nil,
      folder: nil,
      newer_folder: nil,
      needs_version: entry.needs_version,
      replaces: []
    }
  end

  defp entry_row(%{copy: copy} = entry, replaces) do
    %{
      name: entry.name,
      blob_sha: copy.blob_sha,
      folder: copy.folder,
      newer_folder: entry.newer_folder,
      needs_version: nil,
      replaces: Map.get(replaces, copy.blob_sha, [])
    }
  end

  defp insert_copies(copies) do
    copies
    |> Enum.map(&Map.take(&1, [:blob_sha, :folder, :name, :bytes]))
    |> Enum.chunk_every(500)
    |> Enum.each(
      &Repo.insert_all(Copy, &1,
        on_conflict: {:replace, [:name]},
        conflict_target: [:blob_sha, :folder]
      )
    )
  end

  defp insert_results(results) do
    %{schema_version: version, revision: revision} = Loader.fingerprint()

    results
    |> Enum.map(fn {blob_sha, answer} -> result_row(blob_sha, answer, version, revision) end)
    |> Enum.chunk_every(500)
    |> Enum.each(
      &Repo.insert_all(LoadResult, &1,
        on_conflict: {:replace_all_except, [:id]},
        conflict_target: [:blob_sha, :schema_version, :revision]
      )
    )
  end

  defp result_row(blob_sha, {:ok, definition}, version, revision) do
    {outcome, detail} =
      case definition.unsupported do
        [] -> {:loads, nil}
        codes -> {:not_supported, :erlang.term_to_binary(codes)}
      end

    %{
      blob_sha: blob_sha,
      schema_version: version,
      revision: revision,
      outcome: outcome,
      detail: detail,
      definition_id: definition.id,
      name: definition.name,
      privacy: definition.type,
      language: definition.language,
      description: definition.description,
      replaces: replaces_of({:ok, definition})
    }
  end

  defp result_row(blob_sha, {:error, reason}, version, revision) do
    %{
      blob_sha: blob_sha,
      schema_version: version,
      revision: revision,
      outcome: :fails,
      detail: :erlang.term_to_binary(reason),
      definition_id: nil,
      name: nil,
      privacy: nil,
      language: nil,
      description: nil,
      replaces: []
    }
  end

  defp replaces_of({:ok, definition}), do: definition.replaces || []
  defp replaces_of({:error, _reason}), do: []

  defp delete_unused(version, revision) do
    Repo.delete_all(
      from(c in Copy,
        as: :copy,
        where:
          not exists(
            from(e in Entry,
              where:
                e.blob_sha == parent_as(:copy).blob_sha and e.folder == parent_as(:copy).folder
            )
          ) and
            not exists(
              from(p in Pin,
                where:
                  p.running_copy_id == parent_as(:copy).id or
                    p.held_copy_id == parent_as(:copy).id
              )
            )
      )
    )

    Repo.delete_all(
      from(r in LoadResult,
        as: :result,
        where:
          r.schema_version != ^version or r.revision != ^revision or
            not exists(from(c in Copy, where: c.blob_sha == parent_as(:result).blob_sha))
      )
    )
  end

  @doc """
  Lets the next answer at `commit` pass the shrink guard, once the set state refused it as shrunk
  or as a first answer under 100 names. Any other state or commit answers `{:error,
  :not_refused}`. An answer at another commit meets the guard as usual, and its refusal drops the
  acceptance; a successful apply clears it too. It never lifts a `:cinder_too_old` refusal.
  """
  @spec accept_smaller_set(String.t()) :: :ok | {:error, :not_refused}
  def accept_smaller_set(commit) when is_binary(commit) do
    query =
      from(s in StoredSet,
        where:
          s.id == @set_id and s.state in [:shrank, :first_too_small] and
            s.refused_commit == ^commit
      )

    case Repo.update_all(query, set: [accepted_commit: commit]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_refused}
    end
  end

  @doc """
  The set state at `now`, first match:

  - `{:never_loaded, %{error: tag}}`: no set was ever applied or refused; `tag` is the last
    update run's error tag (`Cinder.Indexers.Definitions.Updater`), nil unless that run failed;
  - the last apply's refusal, which carries the set the mirror still holds;
  - `{:update_failing, %{since: at, error: tag, loaded: loaded}}`: a set is loaded, every update
    run since `at` failed, and the last success ended more than 72 hours before `now` (the set's
    `loaded_at` when no run succeeded yet). `tag` is the last run's error tag;
  - `{:loaded, loaded}`.
  """
  @spec set_state(DateTime.t()) :: state()
  def set_state(now \\ DateTime.utc_now()) do
    run = Repo.get(UpdateRun, UpdateRun.id())

    case Repo.get(StoredSet, @set_id) do
      nil -> {:never_loaded, %{error: UpdateRun.error(run)}}
      row -> row |> state_of() |> failing(run, now)
    end
  end

  @doc "The set the mirror holds, nil before any load."
  @spec loaded() :: loaded() | nil
  def loaded do
    case Repo.get(StoredSet, @set_id) do
      nil -> nil
      row -> loaded_of(row)
    end
  end

  defp failing(
         {:loaded, loaded} = state,
         %UpdateRun{first_failure_at: %DateTime{} = since} = run,
         now
       ) do
    if DateTime.diff(now, run.last_success_at || loaded.loaded_at) > @failing_after_s,
      do: {:update_failing, %{since: since, error: UpdateRun.error(run), loaded: loaded}},
      else: state
  end

  defp failing(state, _run, _now), do: state

  defp state_of(%StoredSet{state: :loaded} = row), do: {:loaded, loaded_of(row)}

  defp state_of(%StoredSet{state: :cinder_too_old} = row) do
    {:cinder_too_old,
     %{
       commit: row.refused_commit,
       min_version: String.to_integer(row.refused_versions["MIN_VERSION"]),
       loaded: loaded_of(row)
     }}
  end

  defp state_of(%StoredSet{state: :shrank} = row) do
    {:shrank,
     %{
       percent: row.shrink_percent,
       commit: row.refused_commit,
       count: row.refused_count,
       loaded: loaded_of(row)
     }}
  end

  defp state_of(%StoredSet{state: :first_too_small} = row) do
    {:first_too_small,
     %{commit: row.refused_commit, count: row.refused_count, loaded: loaded_of(row)}}
  end

  defp loaded_of(%StoredSet{commit: nil}), do: nil

  defp loaded_of(row), do: %{count: row.count, commit: row.commit, loaded_at: row.loaded_at}

  @doc """
  The stored copies with no load result under the current fingerprint, one per blob hash.
  """
  @spec stale_copies() :: [copy()]
  def stale_copies do
    from(c in Copy,
      as: :copy,
      where:
        not exists(
          from(r in LoadResult,
            where: r.blob_sha == parent_as(:copy).blob_sha and current_fingerprint(r)
          )
        ),
      distinct: true,
      select: %{blob_sha: c.blob_sha, bytes: c.bytes},
      order_by: c.blob_sha
    )
    |> Repo.all()
  end

  @doc """
  Runs the load check on each copy, at most `ParserWorker.max_check_workers/0` at a time, and
  returns `{blob_sha, answer}` for each check that returned. A check that raises or runs past
  `:timeout_ms` (`check_timeout_ms/0` unless set) is logged and has no answer. Writes nothing.

  `opts`: `:check`, as `apply_set/2` takes it, and `:timeout_ms`.
  """
  @spec check_copies([copy()], keyword()) :: [{String.t(), {:ok, map()} | {:error, term()}}]
  def check_copies(copies, opts \\ []) do
    check = Keyword.get(opts, :check, &LoadCheck.check/1)

    copies
    |> Task.async_stream(&run_check(check, &1),
      max_concurrency: ParserWorker.max_check_workers(),
      timeout: Keyword.get(opts, :timeout_ms, @check_timeout_ms),
      on_timeout: :kill_task
    )
    |> Enum.zip(copies)
    |> Enum.flat_map(fn
      {{:ok, {:ok, answer}}, copy} ->
        [{copy.blob_sha, answer}]

      {{:ok, :raised}, _copy} ->
        []

      {{:exit, :timeout}, copy} ->
        Logger.warning("indexer definition load check timed out: blob #{copy.blob_sha}")
        []
    end)
  end

  # A check that raises, throws or exits is a bug in Cinder, not a fact about the copy: it stores
  # no result, so the next boot re-check runs it again, and the other copies still apply. The
  # log names the exception's module or the kind, never a message or the task's arguments, which
  # can quote a URL from the copy; caught here, the task ends normally and prints no crash report.
  defp run_check(check, copy) do
    {:ok, check.(copy.bytes)}
  rescue
    exception -> check_raised(copy, inspect(exception.__struct__))
  catch
    kind, _value -> check_raised(copy, Atom.to_string(kind))
  end

  defp check_raised(copy, what) do
    Logger.error("indexer definition load check raised on blob #{copy.blob_sha}: #{what}")
    :raised
  end

  @doc """
  Stores `check_copies/2`'s answers under the current fingerprint, in one transaction, sets
  each mirror entry's `replaces` from its copy's new answer, and decides every configured
  indexer's copies again. An answer for a blob hash no stored copy has any more, since an apply
  deleted it meanwhile, is dropped. `{:error, changeset}` is a refused audit row of a base URL
  move, which rolls the whole store back.
  """
  @spec store_results([{String.t(), {:ok, map()} | {:error, term()}}]) ::
          :ok | {:error, Ecto.Changeset.t()}
  def store_results(results) do
    result =
      Repo.transact(fn ->
        stored = MapSet.new(Repo.all(from(c in Copy, distinct: true, select: c.blob_sha)))
        kept = Enum.filter(results, &MapSet.member?(stored, elem(&1, 0)))
        insert_results(kept)

        for {blob_sha, answer} <- kept do
          Repo.update_all(from(e in Entry, where: e.blob_sha == ^blob_sha),
            set: [replaces: replaces_of(answer)]
          )
        end

        decide_pins()
        {:ok, :ok}
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  @doc """
  What the mirror says about one file name (`"nyaasi.yml"`), first match in this order:

  - `:never_loaded`: no set was ever applied;
  - `:in_mirror`: the mirror holds a copy of it;
  - `{:replaced_by, name}`: a mirror copy lists the name's stem (`"nyaasi"`) under `replaces`;
    the first such name in name order;
  - `{:needs_newer_cinder, version}`: only folders above the engine hold it, the lowest of them
    being `version`;
  - `:removed_upstream`.
  """
  @spec name_status(String.t()) :: name_status()
  def name_status(name) when is_binary(name) do
    stored = Repo.get(StoredSet, @set_id)
    entry = Repo.get_by(Entry, name: name)

    cond do
      stored == nil or stored.commit == nil -> :never_loaded
      entry != nil and entry.blob_sha != nil -> :in_mirror
      replacer = replacer(name) -> {:replaced_by, replacer}
      entry != nil -> {:needs_newer_cinder, entry.needs_version}
      true -> :removed_upstream
    end
  end

  defp replacer(name) do
    stem = Path.rootname(name, ".yml")

    from(e in Entry,
      where:
        not is_nil(e.blob_sha) and
          fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)", e.replaces, ^stem),
      order_by: e.name,
      limit: 1,
      select: e.name
    )
    |> Repo.one()
  end

  @doc """
  The mirror's file names in name order, each with its definition's display `id`, its `title`
  (the definition's `name`), privacy, language and description, and its load result. A copy with no result under the current
  fingerprint reads `:unchecked` with no display fields: no check ran under it yet, or the check
  raised or timed out. A copy that fails to load has no display fields either.
  """
  @spec picker() :: [
          %{
            name: String.t(),
            id: String.t() | nil,
            title: String.t() | nil,
            privacy: String.t() | nil,
            language: String.t() | nil,
            description: String.t() | nil,
            result: result() | :unchecked
          }
        ]
  def picker do
    from(e in Entry,
      left_join: r in LoadResult,
      on: r.blob_sha == e.blob_sha and current_fingerprint(r),
      where: not is_nil(e.blob_sha),
      order_by: e.name,
      select: {e.name, r}
    )
    |> Repo.all()
    |> Enum.map(fn {name, row} -> picker_row(name, row) end)
  end

  defp picker_row(name, nil),
    do: %{
      name: name,
      id: nil,
      title: nil,
      privacy: nil,
      language: nil,
      description: nil,
      result: :unchecked
    }

  defp picker_row(name, row) do
    %{
      name: name,
      id: row.definition_id,
      title: row.name,
      privacy: row.privacy,
      language: row.language,
      description: row.description,
      result: result(row)
    }
  end

  # Only rows under the current fingerprint reach here, so every atom in `detail` exists.
  defp result(%LoadResult{outcome: :loads}), do: :loads

  defp result(%LoadResult{outcome: :not_supported, detail: detail}),
    do: {:not_supported, :erlang.binary_to_term(detail, [:safe])}

  defp result(%LoadResult{outcome: :fails, detail: detail}),
    do: {:fails, :erlang.binary_to_term(detail, [:safe])}

  @typedoc "A copy `pin/2` checked: its row id, its blob hash and its loaded definition."
  @type pinned :: %{copy_id: pos_integer(), blob_sha: String.t(), definition: map()}

  @typedoc "A configured indexer's definition code (`indexer_codes/0`)."
  @type indexer_code ::
          {:not_supported, term()}
          | {:no_longer_loads, Loader.reason()}
          | {:held, Hold.reason() | {:needs_newer_cinder, pos_integer()}}
          | {:replaced_by, String.t()}
          | :removed_upstream

  @doc """
  Checks the copy a Cardigann create pins: the mirror's copy of the file `name` must have the
  blob hash `blob_sha`, else `{:error, :not_in_mirror}`, and must load, else `{:error, :fails}`.
  A copy that reads not supported pins. Writes nothing; `attach_pin/2` writes the pin.
  """
  @spec pin(String.t(), String.t()) :: {:ok, pinned()} | {:error, :not_in_mirror | :fails}
  def pin(name, blob_sha) when is_binary(name) and is_binary(blob_sha) do
    case mirror_copy(name) do
      %Copy{blob_sha: ^blob_sha} = copy -> pinned(copy)
      _other -> {:error, :not_in_mirror}
    end
  end

  def pin(_name, _blob_sha), do: {:error, :not_in_mirror}

  # The load check fails a copy only where the loader does (`LoadCheck.check/2`), so the loader
  # alone decides here and also gives the definition the create checks against.
  defp pinned(copy) do
    case Loader.load(copy.bytes) do
      {:ok, definition} ->
        {:ok, %{copy_id: copy.id, blob_sha: copy.blob_sha, definition: definition}}

      {:error, _reason} ->
        {:error, :fails}
    end
  end

  @doc "Writes the pin of the new configured indexer `id`: it runs the `pinned` copy."
  @spec attach_pin(pos_integer(), pinned()) :: :ok
  def attach_pin(id, %{copy_id: copy_id}) do
    Repo.insert!(%Pin{configured_indexer_id: id, running_copy_id: copy_id})
    :ok
  end

  @doc """
  The loaded definition of the copy the configured indexer `id` runs: `{:error, :no_pin}` for
  an indexer with no pin, the loader's `{:error, reason}` for a copy that no longer parses.
  """
  @spec running_definition(pos_integer()) :: {:ok, map()} | {:error, term()}
  def running_definition(id) do
    case Repo.get(Pin, id) do
      nil -> {:error, :no_pin}
      pin -> Repo.get!(Copy, pin.running_copy_id).bytes |> Loader.load()
    end
  end

  @doc """
  The copy the configured indexer `id` runs, as a search reads it (#1671): `{:ok, %{definition:,
  result:, blob_sha:}}`, `definition` the loaded copy, `blob_sha` its hash, which the edit form
  carries (#1676), and `result` its load result under the current fingerprint (`:unchecked` when none is stored yet, `:loads`, `{:not_supported, codes}` or
  `{:fails, reason}`). `{:error, :no_pin}` for an indexer with no pin, `{:error, :fails}` for a
  copy that no longer parses.
  """
  @spec running_copy(pos_integer()) ::
          {:ok, %{definition: map(), result: term(), blob_sha: String.t()}}
          | {:error, :no_pin | :fails}
  def running_copy(id) do
    with %Pin{} = pin <- Repo.get(Pin, id) || {:error, :no_pin},
         copy = Repo.get!(Copy, pin.running_copy_id),
         {:ok, definition} <- loaded(copy) do
      {:ok, %{definition: definition, result: result_of(copy.blob_sha), blob_sha: copy.blob_sha}}
    end
  end

  @doc """
  The hash of the copy the configured indexer `id` runs, nil for an indexer with no pin. An edit
  compares it with the hash its form was rendered from (#1676).
  """
  @spec running_blob_sha(pos_integer()) :: String.t() | nil
  def running_blob_sha(id) do
    from(p in Pin,
      join: c in Copy,
      on: c.id == p.running_copy_id,
      where: p.configured_indexer_id == ^id,
      select: c.blob_sha
    )
    |> Repo.one()
  end

  @typedoc "What `import_copy/1` answers for one file name."
  @type import_copy ::
          :never_loaded
          | :unavailable
          | :needs_newer_cinder
          | {:in_mirror,
             %{blob_sha: String.t(), definition: map() | nil, result: result() | :unchecked}}

  @doc """
  The mirror's copy of the file `name` (`"nyaasi.yml"`) as the Prowlarr import reads it (#1675):
  `:never_loaded` before any set was applied; `{:in_mirror, copy}` with the copy's blob hash, its
  loaded definition (nil when the loader refuses the bytes) and its load result under the current
  fingerprint (`:unchecked` with none stored); `:needs_newer_cinder` when only folders above the
  engine hold it; `:unavailable` when it was removed upstream, is not in the mirror, or another
  name replaces it. Writes nothing.
  """
  @spec import_copy(String.t()) :: import_copy()
  def import_copy(name) when is_binary(name) do
    case name_status(name) do
      :never_loaded -> :never_loaded
      :in_mirror -> in_mirror(mirror_copy(name))
      {:needs_newer_cinder, _version} -> :needs_newer_cinder
      _removed_or_replaced -> :unavailable
    end
  end

  # An apply between the two reads can drop the copy.
  defp in_mirror(nil), do: :unavailable

  defp in_mirror(%Copy{} = copy) do
    definition =
      case Loader.load(copy.bytes) do
        {:ok, definition} -> definition
        {:error, _reason} -> nil
      end

    {:in_mirror,
     %{blob_sha: copy.blob_sha, definition: definition, result: result_of(copy.blob_sha)}}
  end

  defp mirror_copy(name) do
    from(c in Copy,
      join: e in Entry,
      on: e.blob_sha == c.blob_sha and e.folder == c.folder,
      where: e.name == ^name
    )
    |> Repo.one()
  end

  # The copy's load result under the current fingerprint, `:unchecked` with none.
  defp result_of(blob_sha) do
    case Repo.one(
           from(r in LoadResult, where: r.blob_sha == ^blob_sha and current_fingerprint(r))
         ) do
      nil -> :unchecked
      row -> result(row)
    end
  end

  # Decides every pinned Cardigann configured indexer's copies, inside the caller's transaction.
  defp decide_pins do
    pins = Map.new(Repo.all(Pin), &{&1.configured_indexer_id, &1})

    for {row, settings} <- Indexers.cardigann_indexers(), pin = pins[row.id], pin != nil do
      decide_pin(row, settings, pin)
    end

    :ok
  end

  defp decide_pin(row, settings, pin) do
    running = Repo.get!(Copy, pin.running_copy_id)
    running_definition = Loader.load(running.bytes)
    {mirror, newer} = mirror_of(row.definition)

    input = %{
      running: %{blob_sha: running.blob_sha, definition: running_definition},
      mirror: mirror && candidate(mirror),
      newer: newer,
      stored_url: row.base_url,
      settings: settings
    }

    case Hold.decide(input) do
      :unchanged ->
        :ok

      {:keep, newer} ->
        write_pin(pin, pin.running_copy_id, nil, newer)

      {:hold, reason} ->
        write_pin(pin, pin.running_copy_id, mirror.id, reason)

      {:apply, newer} ->
        audit_move(
          row,
          settings,
          {running, running_definition},
          {mirror, input.mirror.definition}
        )

        write_pin(pin, mirror.id, nil, newer)
    end
  end

  # The mirror's copy of the file `name` (nil with none), and the folder above the engine that
  # holds another copy of it (nil with none).
  defp mirror_of(name) do
    case Repo.get_by(Entry, name: name) do
      nil -> {nil, nil}
      %Entry{blob_sha: nil} = entry -> {nil, entry.needs_version}
      entry -> {mirror_copy(name), entry.newer_folder}
    end
  end

  defp candidate(copy),
    do: %{
      blob_sha: copy.blob_sha,
      result: result_of(copy.blob_sha),
      definition: Loader.load(copy.bytes)
    }

  defp write_pin(pin, running_id, held_id, hold) do
    hold = if hold, do: :erlang.term_to_binary(hold)

    if {pin.running_copy_id, pin.held_copy_id, pin.hold} != {running_id, held_id, hold} do
      pin
      |> Ecto.Changeset.change(running_copy_id: running_id, held_copy_id: held_id, hold: hold)
      |> Repo.update!()
    end

    :ok
  end

  # #1616 rule 13: an applied copy that moves a public indexer's effective base URL.
  defp audit_move(row, settings, {old, old_definition}, {new, {:ok, new_definition}}) do
    old_url =
      case old_definition do
        {:ok, definition} -> CredentialHosts.effective_base_url(definition, row.base_url)
        {:error, _reason} -> nil
      end

    new_url = CredentialHosts.effective_base_url(new_definition, row.base_url)

    if new_url != old_url and not Hold.credentials?(old_definition, settings) do
      Audit.log_or_rollback(
        nil,
        "move_configured_indexer_base_url",
        {"ConfiguredIndexer", row.id},
        %{
          fields: ["base_url"],
          from_copy: old.blob_sha,
          to_copy: new.blob_sha
        }
      )
    end

    :ok
  end

  @doc """
  Accepts the held definition update of the configured indexer `id`, whose held copy the admin
  saw as `blob_sha`, in one transaction (#1616 rule 6, #1620 point 12). It refuses, first match:

  - `{:error, :not_found}`: no Cardigann configured indexer `id`, or one with no pin;
  - `{:error, :undecryptable}`: its secrets do not decrypt;
  - `{:error, :stale}`: no copy is held, or the held copy's hash is not `blob_sha`;
  - `{:error, :not_acceptable}`: the hold's reason is not a credential rule
    (`Hold.credential_reasons/0`).

  Otherwise the held copy becomes the running copy, the copies are decided again, the indexer's
  `config_version` rises through `Cinder.Indexers.bump_config_version/1`, and one audit row
  names the reason and the two copy hashes, never a setting value. `{:error, changeset}` is a
  refused audit row, which rolls it all back.
  """
  @spec accept(pos_integer(), String.t(), Indexers.actor()) ::
          :ok
          | {:error, :not_found | :undecryptable | :stale | :not_acceptable | Ecto.Changeset.t()}
  def accept(id, blob_sha, actor) do
    Repo.transact(fn ->
      with {:ok, row, settings, pin} <- held_indexer(id),
           {:ok, held} <- held_copy(pin, blob_sha),
           {:ok, reason} <- acceptable(pin) do
        running = Repo.get!(Copy, pin.running_copy_id)
        :ok = write_pin(pin, held.id, nil, nil)
        decide_pin(row, settings, Repo.get!(Pin, id))
        :ok = Indexers.bump_config_version(id)

        Audit.log_or_rollback(
          actor,
          "accept_configured_indexer_definition",
          {"ConfiguredIndexer", id},
          %{
            fields: ["definition"],
            reason: Atom.to_string(reason),
            from_copy: running.blob_sha,
            to_copy: held.blob_sha
          }
        )

        {:ok, :accepted}
      end
    end)
    |> case do
      {:ok, :accepted} -> :ok
      error -> error
    end
  end

  defp held_indexer(id) do
    case {Enum.find(Indexers.cardigann_indexers(), &(elem(&1, 0).id == id)), Repo.get(Pin, id)} do
      {nil, _pin} -> {:error, :not_found}
      {_row, nil} -> {:error, :not_found}
      {{_row, :undecryptable}, _pin} -> {:error, :undecryptable}
      {{row, settings}, pin} -> {:ok, row, settings, pin}
    end
  end

  defp held_copy(%Pin{held_copy_id: nil}, _blob_sha), do: {:error, :stale}

  defp held_copy(pin, blob_sha) do
    case Repo.get!(Copy, pin.held_copy_id) do
      %Copy{blob_sha: ^blob_sha} = held -> {:ok, held}
      _other -> {:error, :stale}
    end
  end

  defp acceptable(pin) do
    reason = hold_of(pin)
    if reason in Hold.credential_reasons(), do: {:ok, reason}, else: {:error, :not_acceptable}
  end

  defp hold_of(%Pin{hold: nil}), do: nil
  defp hold_of(%Pin{hold: hold}), do: :erlang.binary_to_term(hold, [:safe])

  @doc """
  The credential hosts the held copy of the configured indexer `id` names that its running copy
  does not, sorted (`CredentialHosts.hosts/2`), for Accept's confirm. Every host of the held
  copy when the running copy no longer parses, or when the held copy declares a stored secret
  again (`Hold.declares_again?/3`), since the running copy sent that secret nowhere. The hosts
  are read with each stored secret standing as its own template, since the confirm renders them:
  a host a secret fills is `{:unknown, raw}`. Refuses `:not_found` and `:undecryptable` as
  `accept/3` does, `:stale` with no held copy, and `:fails` for a held copy that does not parse.
  """
  @spec held_hosts(pos_integer()) ::
          {:ok, [CredentialHosts.host()]}
          | {:error, :not_found | :undecryptable | :stale | :fails}
  def held_hosts(id) do
    with {:ok, %{hosts: hosts}} <- held_update(id), do: {:ok, hosts}
  end

  @doc """
  The held definition update of the configured indexer `id`, from one read of its pin, for
  Accept's confirm (#1676): `{:ok, %{blob_sha:, reason:, hosts:}}`, the held copy's hash, the
  hold's reason, and the hosts `held_hosts/1` lists. Refuses as `held_hosts/1` does.
  """
  @spec held_update(pos_integer()) ::
          {:ok, %{blob_sha: String.t(), reason: term(), hosts: [CredentialHosts.host()]}}
          | {:error, :not_found | :undecryptable | :stale | :fails}
  def held_update(id) do
    with {:ok, row, settings, pin} <- held_indexer(id),
         {:ok, held} <- held_any(pin),
         {:ok, hosts} <- added_hosts(row, settings, pin, held) do
      {:ok, %{blob_sha: held.blob_sha, reason: hold_of(pin), hosts: hosts}}
    end
  end

  defp added_hosts(row, settings, pin, held) do
    with {:ok, held_definition} <- loaded(held) do
      stored = %{stored_url: row.base_url, settings: shown_values(settings)}

      running = Loader.load(Repo.get!(Copy, pin.running_copy_id).bytes)

      running_hosts =
        if match?({:ok, _}, running) and
             not Hold.declares_again?(running, held_definition, settings),
           do: CredentialHosts.hosts(elem(running, 1), stored),
           else: MapSet.new()

      held_definition
      |> CredentialHosts.hosts(stored)
      |> MapSet.difference(running_hosts)
      |> Enum.sort()
      |> then(&{:ok, &1})
    end
  end

  # The stored values the confirms' hosts are read under. The pages render those hosts, so each
  # stored secret stands as its own template: a host it fills reads as `{:unknown, raw}`, and a
  # secret that holds a URL as `{:unknown, "{{ .Config.<key> }}"}` (`CredentialHosts.hosts/2`).
  # Hold's rules still read the real values.
  defp shown_values(settings) do
    masked =
      Map.new(settings.secrets, fn {key, value} ->
        template = "{{ .Config.#{key} }}"
        {key, if(is_binary(value) and value =~ "://", do: "https://" <> template, else: template)}
      end)

    Map.merge(settings.plain, masked)
  end

  defp held_any(%Pin{held_copy_id: nil}), do: {:error, :stale}
  defp held_any(pin), do: {:ok, Repo.get!(Copy, pin.held_copy_id)}

  @doc """
  When the definitions were last checked: the end of the last update run that succeeded, an
  unchanged commit included (#1616 rule 12), or the loaded set's `loaded_at` when that is later;
  nil before any load.
  """
  @spec last_checked_at() :: DateTime.t() | nil
  def last_checked_at do
    run = Repo.get(UpdateRun, UpdateRun.id())
    times = [run && run.last_success_at, loaded() && loaded().loaded_at]

    case Enum.reject(times, &is_nil/1) do
      [] -> nil
      found -> Enum.max(found, DateTime)
    end
  end

  defp loaded(copy) do
    case Loader.load(copy.bytes) do
      {:ok, definition} -> {:ok, definition}
      {:error, _reason} -> {:error, :fails}
    end
  end

  @doc """
  Each pinned configured indexer's definition code, by id; an indexer with none is left out.
  First match:

  - `{:not_supported, feature}`: its running copy reads not supported, `feature` the first code;
  - `{:no_longer_loads, reason}`: its running copy fails to load on this build;
  - `{:held, reason}`: an update is held, `reason` as `Hold.decide/1` gives it, or
    `{:needs_newer_cinder, version}`;
  - `{:replaced_by, name}` and `:removed_upstream`, from `name_status/1`.

  A running copy with no load result under the current fingerprint reads as neither red code.
  """
  @spec indexer_codes() :: %{pos_integer() => indexer_code()}
  def indexer_codes do
    from(p in Pin,
      join: c in Copy,
      on: c.id == p.running_copy_id,
      join: i in ConfiguredIndexer,
      on: i.id == p.configured_indexer_id,
      select: {p, c.blob_sha, i.definition}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {pin, blob_sha, name} ->
      case indexer_code(pin, result_of(blob_sha), name) do
        nil -> []
        code -> [{pin.configured_indexer_id, code}]
      end
    end)
    |> Map.new()
  end

  @doc """
  Each pinned configured indexer's held update, by id, whatever its `indexer_codes/0` code
  (#1676): `held`, the hold's reason as `{:held, reason}` gives it, nil with none. A red code
  outranks it in `indexer_codes/0`, but Accept update is the way to a copy that runs, so the
  table reads it here.
  """
  @spec indexer_actions() :: %{pos_integer() => %{held: term() | nil}}
  def indexer_actions do
    from(p in Pin, join: i in ConfiguredIndexer, on: i.id == p.configured_indexer_id, select: p)
    |> Repo.all()
    |> Map.new(&{&1.configured_indexer_id, %{held: hold_of(&1)}})
  end

  defp indexer_code(_pin, {:not_supported, [feature | _]}, _name), do: {:not_supported, feature}
  defp indexer_code(_pin, {:fails, reason}, _name), do: {:no_longer_loads, reason}

  defp indexer_code(%Pin{hold: hold} = pin, _result, _name) when hold != nil,
    do: {:held, hold_of(pin)}

  defp indexer_code(_pin, _result, name) do
    case name_status(name) do
      {:replaced_by, replacer} -> {:replaced_by, replacer}
      :removed_upstream -> :removed_upstream
      _other -> nil
    end
  end
end
