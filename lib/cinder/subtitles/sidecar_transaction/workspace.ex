defmodule Cinder.Subtitles.SidecarTransaction.Workspace do
  @moduledoc false
  # The workspace an `AtomicFile` operation works in beside its target: its persisted names, and
  # retiring what operations left there once nothing reads it (`retire/2`, `sweep/3`).

  require Logger

  alias __MODULE__.Sweep

  import Cinder.Subtitles.SafeFile, only: [fs: 0, safe_destination: 1, safe_read: 1]
  import Cinder.Subtitles.SidecarTransaction.Bound, only: [verify_bound_path: 2, with_bound: 3]

  @operation_id ~r/\A[A-Za-z0-9_-]{22}\z/
  @workspace_prefix ".cinder-subtitle-sync-cas-"
  @staged_name ".cinder-subtitle-sync-write-staged"
  # Only `AtomicFile`'s `replace_shared_tombstone/2` creates this name, after its exchange
  # committed.
  @tombstone_name ".cinder-subtitle-sync-write-tombstone"
  # A sweep leaves a workspace that changed within this long: an operation still at work in it,
  # under another video's lock, changed it moments ago.
  @sweep_min_age_seconds 3_600
  # Each workspace a sweep retires costs a few rooted-helper calls under the video's lock.
  @sweep_limit 50

  @doc "Whether `operation_id` is one a workspace can be named after."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(operation_id),
    do: is_binary(operation_id) and Regex.match?(@operation_id, operation_id)

  @doc "The workspace of `operation_id` beside `target`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(target, operation_id),
    do: Path.join(Path.dirname(target), @workspace_prefix <> operation_id)

  @doc "The staged name in the workspace `directory`."
  @spec staged_path(String.t()) :: String.t()
  def staged_path(directory), do: Path.join(directory, @staged_name)

  @doc "The fresh tombstone's name in the workspace `directory`."
  @spec tombstone_path(String.t()) :: String.t()
  def tombstone_path(directory), do: Path.join(directory, @tombstone_name)

  @doc """
  Removes the workspace `AtomicFile.write/4` used for `operation_id` beside `target`. Call it once
  the final record that ends that correction is written: nothing reads the workspace after that.

  The workspace goes only while it is a bare tombstone: the staged name alone, on an empty
  regular file with no other name, or no entry at all. One already gone counts as removed.

  A disposal killed between creating its fresh tombstone and renaming it over the staged name
  (`AtomicFile`'s `replace_shared_tombstone/2`), or whose rename failed, leaves two entries: the
  staged name on a regular file with another name, a download's file for one, and the fresh
  tombstone, an empty regular file with one name. That workspace goes too: renaming the fresh
  tombstone over the staged name finishes the disposal, which drops only the workspace's name
  for the shared file and never writes it.

  Anything else stays, and a warning names its path, as does a step that fails.

  Returns `:removed` when the workspace is gone, `:kept` when it stays.
  """
  @spec retire(String.t(), String.t()) :: :removed | :kept
  def retire(target, operation_id) do
    directory = path(target, operation_id)

    result =
      if valid_id?(operation_id),
        do: directory |> classify_workspace(nil) |> retire_classified(nil),
        else: {:error, :invalid_operation_id}

    case result do
      {_kept_or_error, reason} ->
        log_kept_workspace(directory, reason)
        :kept

      _removed_or_absent ->
        :removed
    end
  end

  @doc """
  Removes the workspaces earlier operations left in `directory`, up to `:limit` of them (50 by
  default), and returns how many it removed.

  `records.(names)`, where `names` is what `directory` lists, returns
  `{:ok, protected, candidates}`: the operation ids that the records in the directory still
  name, and the files whose bytes Cinder keeps there. Or it returns `{:error, reason}` when a
  record it cannot read could name any workspace: the sweep then removes nothing, and one
  warning names the directory and the reason. `records` runs only when `directory` holds a
  workspace.

  A workspace whose id is not among `protected`, and whose directory and entries have not changed
  for an hour, goes while it is one of these:

    * a bare tombstone or an interrupted disposal (killed, or whose rename failed), as
      `retire/2` says;
    * the staged name alone, on a non-empty regular file with any link count, whose bytes equal
      one of `candidates`. Only a candidate of the same size is read. The removal holds the
      staged inode, checks through its descriptor the same age and those bytes, and removes the
      name only while it still names that inode. It never opens that inode for writing, so its
      other names, such as a download's, keep its bytes.

  A workspace that fails a step stays, and a warning names its path. One whose bytes no
  candidate holds stays without a warning.

  The caller holds one video's lock, but the workspaces of every video in `directory` sit there.
  Another video's operation that is still at work changed its workspace within the hour.
  `protected` covers a pending correction and the reversals a record's reset or rollback would
  reuse. Any other tombstone is safe to remove: a later reversal that needs its name makes a
  fresh workspace. An interrupted disposal's staged name holds an inode its exchange displaced,
  never bytes waiting to be published, and bytes a candidate holds stay in that candidate.
  """
  @spec sweep(
          String.t(),
          ([String.t()] -> {:ok, Enumerable.t(), [String.t()]} | {:error, term()}),
          keyword()
        ) :: non_neg_integer()
  def sweep(directory, records, opts \\ []) do
    case fs().ls(directory) do
      {:ok, names} ->
        sweep_names(directory, names, records, Keyword.get(opts, :limit, @sweep_limit))

      {:error, reason} ->
        log_not_swept(directory, reason)
        0
    end
  end

  defp sweep_names(directory, names, records, limit) do
    case Enum.flat_map(names, &workspace_id/1) do
      [] -> 0
      ids -> sweep_recorded(directory, names, ids, records, limit)
    end
  end

  defp sweep_recorded(directory, names, ids, records, limit) do
    case records.(names) do
      {:ok, protected, candidates} ->
        sweep_ids(directory, ids, MapSet.new(protected), candidates, limit)

      {:error, reason} ->
        log_not_swept(directory, reason)
        0
    end
  end

  defp sweep_ids(directory, ids, protected, candidates, limit) do
    cutoff = gregorian_now() - @sweep_min_age_seconds
    sweep = %Sweep{budget: limit, candidates: {:unindexed, candidates}}

    ids
    |> Enum.reject(&MapSet.member?(protected, &1))
    |> Enum.reduce_while(sweep, fn id, sweep ->
      sweep_workspace(Path.join(directory, @workspace_prefix <> id), cutoff, sweep)
    end)
    |> then(& &1.removed)
  end

  defp log_not_swept(directory, reason),
    do: Logger.warning("subtitle workspaces not swept in #{directory}: #{inspect(reason)}")

  defp workspace_id(@workspace_prefix <> id),
    do: if(Regex.match?(@operation_id, id), do: [id], else: [])

  defp workspace_id(_name), do: []

  # Only a workspace that looks retirable spends the limit: the checks before it read metadata in
  # this process, the removal goes through the rooted helper.
  defp sweep_workspace(_directory, _cutoff, %Sweep{budget: 0} = sweep), do: {:halt, sweep}

  defp sweep_workspace(directory, cutoff, sweep) do
    case classify_workspace(directory, cutoff) do
      {kind, _path} = retirable when kind in [:tombstone, :empty, :interrupted] ->
        retirable
        |> retire_classified(cutoff)
        |> count_swept(directory, spend(sweep))

      {:holds_bytes, staged_path, size} ->
        sweep_bytes(directory, staged_path, size, cutoff, index_candidates(sweep))

      {:error, reason} ->
        log_kept_workspace(directory, reason)
        {:cont, sweep}

      _absent_or_kept ->
        {:cont, sweep}
    end
  end

  # Bytes the folder may keep elsewhere: only a candidate of their size can hold them, so a
  # workspace with no such candidate is kept unread and spends nothing.
  defp sweep_bytes(directory, staged_path, size, cutoff, sweep) do
    case Map.get(sweep.candidates, size, []) do
      [] ->
        {:cont, sweep}

      candidates ->
        staged_path
        |> retire_accounted(candidates, cutoff)
        |> count_swept(directory, spend(sweep))
    end
  end

  # The candidates by size, read from their metadata once, at the first workspace holding bytes.
  defp index_candidates(%Sweep{candidates: {:unindexed, paths}} = sweep) do
    indexed =
      paths
      |> Enum.uniq()
      |> Enum.flat_map(&candidate_size/1)
      |> Enum.group_by(fn {_path, size} -> size end, fn {path, _size} -> path end)

    %{sweep | candidates: indexed}
  end

  defp index_candidates(sweep), do: sweep

  defp candidate_size(path) do
    with {:ok, path} <- safe_destination(path),
         {:ok, %{type: :regular, size: size}} <- fs().lstat(path),
         do: [{path, size}],
         else: (_missing_or_not_a_file -> [])
  end

  defp spend(sweep), do: %{sweep | budget: sweep.budget - 1}

  defp count_swept(:removed, _directory, sweep),
    do: {:cont, %{sweep | removed: sweep.removed + 1}}

  defp count_swept(:unaccounted, _directory, sweep), do: {:cont, sweep}

  defp count_swept({_kept_or_error, reason}, directory, sweep) do
    log_kept_workspace(directory, reason)
    {:cont, sweep}
  end

  defp log_kept_workspace(directory, reason),
    do: Logger.warning("subtitle workspace kept at #{directory}: #{inspect(reason)}")

  # `:absent`, `{:kept, reason}`, `{:error, reason}`, or what `retire_classified/2` removes:
  # `{:empty, directory}`, `{:tombstone, staged_path}`, `{:interrupted, directory}` or, for a
  # sweep only, `{:holds_bytes, staged_path, size}`. With a `cutoff` (gregorian seconds), a
  # directory or entry modified after it is kept.
  defp classify_workspace(directory, cutoff) do
    with {:ok, directory} <- safe_destination(directory),
         do: classify_directory(directory, fs().lstat(directory), cutoff)
  end

  defp classify_directory(directory, {:ok, %{type: :directory} = stat}, cutoff) do
    if settled?(stat, cutoff),
      do: classify_entries(directory, fs().ls(directory), cutoff),
      else: {:kept, :recent}
  end

  defp classify_directory(_directory, {:ok, _stat}, _cutoff), do: {:kept, :not_a_directory}
  defp classify_directory(_directory, {:error, :enoent}, _cutoff), do: :absent
  defp classify_directory(_directory, {:error, _reason} = error, _cutoff), do: error

  defp classify_entries(directory, {:ok, []}, _cutoff), do: {:empty, directory}

  defp classify_entries(directory, {:ok, [@staged_name]}, cutoff) do
    staged_path = Path.join(directory, @staged_name)

    with {:ok, stat} <- fs().lstat(staged_path), do: classify_staged(staged_path, stat, cutoff)
  end

  defp classify_entries(directory, {:ok, entries}, cutoff)
       when entries in [[@staged_name, @tombstone_name], [@tombstone_name, @staged_name]] do
    with {:ok, staged} <- fs().lstat(Path.join(directory, @staged_name)),
         {:ok, fresh} <- fs().lstat(Path.join(directory, @tombstone_name)),
         :shared <- shared_displaced(staged, cutoff),
         :tombstone <- tombstone(fresh, cutoff),
         do: {:interrupted, directory}
  end

  defp classify_entries(_directory, {:ok, _entries}, _cutoff), do: {:kept, :not_a_tombstone}
  defp classify_entries(_directory, {:error, :enoent}, _cutoff), do: :absent
  defp classify_entries(_directory, {:error, _reason} = error, _cutoff), do: error

  defp classify_staged(staged_path, stat, cutoff) do
    case holds_bytes(stat, cutoff) do
      :holds_bytes -> {:holds_bytes, staged_path, stat.size}
      _not_bytes -> with :tombstone <- tombstone(stat, cutoff), do: {:tombstone, staged_path}
    end
  end

  defp tombstone(%{type: :regular, size: 0, links: 1} = stat, cutoff),
    do: if(settled?(stat, cutoff), do: :tombstone, else: {:kept, :recent})

  defp tombstone(_stat, _cutoff), do: {:kept, :not_a_tombstone}

  # A staged file with bytes, whatever its link count: the inode an exchange displaced, bytes
  # staged for a publication that never ran, or a download's file a disposal that failed before
  # its fresh tombstone's rename left at the staged name (#1187). Dropping the workspace's name
  # for a file with other names leaves them its bytes.
  defp holds_bytes(%{type: :regular, size: size} = stat, cutoff) when size > 0,
    do: if(settled?(stat, cutoff), do: :holds_bytes, else: {:kept, :recent})

  defp holds_bytes(_stat, _cutoff), do: {:kept, :not_a_tombstone}

  # An interrupted disposal's staged file: the displaced inode, which has a name outside the
  # workspace too, so dropping the workspace's name never removes its last one.
  defp shared_displaced(%{type: :regular, links: links} = stat, cutoff) when links > 1,
    do: if(settled?(stat, cutoff), do: :shared, else: {:kept, :recent})

  defp shared_displaced(_stat, _cutoff), do: {:kept, :not_a_tombstone}

  defp settled?(_stat, nil), do: true

  defp settled?(%{mtime: mtime}, cutoff),
    do: :calendar.datetime_to_gregorian_seconds(mtime) <= cutoff

  defp gregorian_now, do: :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

  # `rmdir` refuses a directory that gained an entry since it was listed.
  defp retire_classified({:empty, directory}, _cutoff), do: remove_directory(directory)

  defp retire_classified({:tombstone, staged_path}, cutoff) do
    with {:ok, staged_path} <- safe_destination(staged_path),
         :ok <-
           with_bound(staged_path, [:read, :raw, :binary], fn staged ->
             unlink_tombstone(staged_path, staged, cutoff)
           end),
         do: remove_directory(Path.dirname(staged_path))
  end

  # Finishes the interrupted disposal, which leaves a bare tombstone, then retires that. A kill
  # after any step leaves a state a later retirement still removes: the two entries, the bare
  # tombstone, or no entry.
  defp retire_classified({:interrupted, directory}, cutoff) do
    with {:ok, staged_path} <- safe_destination(Path.join(directory, @staged_name)),
         {:ok, fresh_path} <- safe_destination(Path.join(directory, @tombstone_name)),
         :ok <-
           with_bound(staged_path, [:read, :raw, :binary], fn displaced ->
             finish_disposal(staged_path, displaced, fresh_path, cutoff)
           end),
         do: remove_directory(directory)
  end

  # Bytes are retired only by a sweep, which proves a candidate holds them (`retire_accounted/3`).
  defp retire_classified({:holds_bytes, _staged_path, _size}, _cutoff),
    do: {:kept, :not_a_tombstone}

  defp retire_classified(unretirable, _cutoff), do: unretirable

  defp finish_disposal(staged_path, displaced, fresh_path, cutoff) do
    with_bound(fresh_path, [:read, :raw, :binary], fn fresh ->
      with {:ok, displaced_stat} <- File.stat(displaced.path, [:raw]),
           :shared <- shared_displaced(displaced_stat, cutoff),
           :ok <- rename_fresh_over(staged_path, displaced, fresh_path, fresh, cutoff),
           do: unlink_tombstone(staged_path, fresh, cutoff)
    end)
  end

  @doc """
  Finishes a disposal that left the fresh tombstone at `fresh_path` beside `staged_path`, whose
  inode `displaced` holds: renames the fresh tombstone over the staged name, whatever the
  displaced inode's link count, once its descriptor proves it empty with one link and the staged
  name still names `displaced`. `:ok` means the staged name now holds that empty file, which
  nothing else names. The displaced inode's bytes are never written.

  Only a recovery calls it, once the pending record proves the staged bytes are the ones the
  exchange displaced.
  """
  @spec replace_displaced(String.t(), map(), String.t()) :: :ok | {atom(), term()}
  def replace_displaced(staged_path, displaced, fresh_path) do
    with {:ok, fresh_path} <- safe_destination(fresh_path) do
      with_bound(fresh_path, [:read, :raw, :binary], fn fresh ->
        replace_with_fresh(staged_path, displaced, fresh_path, fresh)
      end)
    end
  end

  defp replace_with_fresh(staged_path, displaced, fresh_path, fresh) do
    with :ok <- rename_fresh_over(staged_path, displaced, fresh_path, fresh, nil),
         do: verify_bound_path(staged_path, fresh)
  end

  defp rename_fresh_over(staged_path, displaced, fresh_path, fresh, cutoff) do
    with {:ok, fresh_stat} <- File.stat(fresh.path, [:raw]),
         :tombstone <- tombstone(fresh_stat, cutoff),
         :ok <- verify_bound_path(fresh_path, fresh),
         do: committed_as_ok(rename_over_displaced(fresh_path, staged_path, displaced))
  end

  # A rename whose effect committed did rename: the caller checks the name next.
  defp committed_as_ok({:error, {:effect_committed, _operation, _detail}}), do: :ok
  defp committed_as_ok(result), do: result

  # Checks the held inode itself, through its descriptor, then removes its one name only while it
  # still names that inode.
  defp unlink_tombstone(staged_path, staged, cutoff) do
    with {:ok, stat} <- File.stat(staged.path, [:raw]),
         :tombstone <- tombstone(stat, cutoff),
         :ok <- verify_bound_path(staged_path, staged),
         do: remove_name(staged_path)
  end

  # The same for a staged file holding bytes, which go only while one of `candidates` (paths of
  # the bytes' size) holds them too. `:unaccounted` when none does.
  defp retire_accounted(staged_path, candidates, cutoff) do
    with {:ok, staged_path} <- safe_destination(staged_path),
         :ok <-
           with_bound(staged_path, [:read, :raw, :binary], fn staged ->
             unlink_accounted(staged_path, staged, candidates, cutoff)
           end),
         do: remove_directory(Path.dirname(staged_path))
  end

  defp unlink_accounted(staged_path, staged, candidates, cutoff) do
    with {:ok, stat} <- File.stat(staged.path, [:raw]),
         :holds_bytes <- holds_bytes(stat, cutoff),
         {:ok, bytes} <- File.read(staged.path, [:raw]),
         :accounted <- accounted(bytes, candidates),
         :ok <- verify_bound_path(staged_path, staged),
         do: remove_name(staged_path)
  end

  defp accounted(bytes, candidates) do
    if Enum.any?(candidates, &(safe_read(&1) == {:ok, bytes})),
      do: :accounted,
      else: :unaccounted
  end

  defp remove_name(path) do
    case fs().rm(path) do
      :ok -> :ok
      {:error, {:effect_committed, _operation, _detail}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Removes the workspace `directory` while it holds no entry: `:removed`, also when it is already
  gone, or `{:kept, :not_a_tombstone}` when it gained one.
  """
  @spec remove_directory(String.t()) :: :removed | {:kept, :not_a_tombstone} | {:error, term()}
  def remove_directory(directory) do
    case fs().rmdir(directory) do
      :ok -> :removed
      {:error, {:effect_committed, _operation, _detail}} -> :removed
      {:error, :enoent} -> :removed
      {:error, reason} when reason in [:eexist, :enotempty] -> {:kept, :not_a_tombstone}
      {:error, _reason} = error -> error
    end
  end

  defp rename_over_displaced(fresh_path, staged_path, current) do
    with :ok <- verify_bound_path(staged_path, current),
         do: fs().rename(fresh_path, staged_path)
  end
end
