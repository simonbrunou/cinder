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
  2. The guard counts the distinct file names in every folder at or above `MIN_VERSION`. With no
     stored set, an answer under 100 names is refused as `:first_too_small`. With a stored set,
     an answer under 90% of its count is refused as `:shrank` by N%, N rounded down. An answer at
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
  transaction, with no network call.

  ## Reads

  - `set_state/0`: never loaded, loaded, or the last refusal.
  - `name_status/1`: what the mirror says about one file name.
  - `picker/0`: the mirror's names with their display fields and load results.

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
    StoredSet
  }

  alias Cinder.Indexers.ParserWorker
  alias Cinder.Repo

  @set_id 1
  @first_floor 100
  @shrink_floor_percent 90
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
  @type state :: :never_loaded | {:loaded, loaded()} | refusal()
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
  Applies an upstream answer. Returns the new set state, or the refusal, which `set_state/0`
  then reads too.

  `opts`: `:check`, the load check run on each copy's bytes (`LoadCheck.check/2` with no options
  unless set; a test seam), and `:timeout_ms`, which `check_copies/2` reads.
  """
  @spec apply_set(Set.t(), keyword()) :: {:ok, state()} | {:error, refusal()}
  def apply_set(%Set{} = set, opts \\ []) do
    stored = Repo.get(StoredSet, @set_id)
    min = set.versions.min

    if min > engine_version() do
      refuse(stored, set, :cinder_too_old, refused_versions: set.versions.values)
    else
      files = counted_files(set)
      count = files |> Enum.uniq_by(& &1.name) |> length()

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

  # The one write of an applied set. #1668 adds the configured indexers' holds and audit here.
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
  The set state: never loaded, loaded, or the last apply's refusal, which carries the set the
  mirror still holds.
  """
  @spec set_state() :: state()
  def set_state do
    case Repo.get(StoredSet, @set_id) do
      nil -> :never_loaded
      row -> state_of(row)
    end
  end

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

  # A check that raises is a bug in Cinder, not a fact about the copy: it stores no result, so the
  # next boot re-check runs it again, and the other copies still apply.
  defp run_check(check, copy) do
    {:ok, check.(copy.bytes)}
  rescue
    exception ->
      Logger.error(
        "indexer definition load check raised on blob #{copy.blob_sha}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :raised
  end

  @doc """
  Stores `check_copies/2`'s answers under the current fingerprint, in one transaction, and sets
  each mirror entry's `replaces` from its copy's new answer. An answer for a blob hash no stored
  copy has any more, since an apply deleted it meanwhile, is dropped.
  """
  @spec store_results([{String.t(), {:ok, map()} | {:error, term()}}]) :: :ok
  def store_results(results) do
    {:ok, :ok} =
      Repo.transact(fn ->
        stored = MapSet.new(Repo.all(from(c in Copy, distinct: true, select: c.blob_sha)))
        kept = Enum.filter(results, &MapSet.member?(stored, elem(&1, 0)))
        insert_results(kept)

        for {blob_sha, answer} <- kept do
          Repo.update_all(from(e in Entry, where: e.blob_sha == ^blob_sha),
            set: [replaces: replaces_of(answer)]
          )
        end

        {:ok, :ok}
      end)

    :ok
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
  The mirror's file names in name order, each with its definition's display `id`, privacy,
  language and description, and its load result. A copy with no result under the current
  fingerprint reads `:unchecked` with no display fields: no check ran under it yet, or the check
  raised or timed out. A copy that fails to load has no display fields either.
  """
  @spec picker() :: [
          %{
            name: String.t(),
            id: String.t() | nil,
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
    do: %{name: name, id: nil, privacy: nil, language: nil, description: nil, result: :unchecked}

  defp picker_row(name, row) do
    %{
      name: name,
      id: row.definition_id,
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
end
