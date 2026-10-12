defmodule Cinder.Download.OrphanFolders do
  @moduledoc """
  Reports and clears the `<title>.cinder-<key>` job folders in the explicit import roots that
  nothing references any more (issue #658, spec `068-orphan-download-folders`).

  Cinder names every usenet job `<title>.cinder-<key>` and the client delivers it into a folder of
  that name. A failed import, a rejected grab or a download client that already forgot the job
  leaves the folder (sometimes a full copy of a library file) with no record pointing at it, and
  nothing else sweeps it. This module is the **report-first** answer: `scan/0` lists such folders
  with a class, `clear/3` removes chosen ones. It never runs on its own.

  ## Classes

    * `:empty` — no regular file anywhere in the folder.
    * `:library_copy` — at least one video, and every video is byte-identical to a library file
      the database knows (same size and OpenSubtitles moviehash, `Cinder.Subtitles.Moviehash`).
    * `:unmatched` — anything else. May be a download that never imported; operator review only.

  A folder is not classified at all (`hold` is set instead of `class`) while a symlink or other
  non-regular entry is inside it, something in it changed in the last hour (a download or unpack
  may still be writing), it is unreadable, or it is implausibly large to walk.

  ## What counts as a reference

  A folder is left out of the report when, by its `<key>`: a configured download client lists a
  Cinder job with that key (`list_managed/0`), a `download_intents` row carries it as its
  operation key, or any grab / movie / book-grab `content_path` or library file path mentions it.
  Matching on the key rather than the path keeps the check independent of mount-prefix
  differences. If any configured client cannot list its jobs the whole operation fails closed
  with `{:error, {:client_list_failed, protocol, reason}}`: with a client blind, "unreferenced"
  cannot be told from "in flight".

  ## Safety

  `clear/3` re-surveys the folder, re-classifies it and re-reads the database references
  immediately before each delete, and deletes through `Cinder.Library.delete_download_source/1`
  — strictly inside an **explicit** import root, no symlinks, never a root itself. The client
  snapshot is taken once per call, which is sound because a folder only exists under a key whose
  job the client already knew when the snapshot was taken, and a later job can only reserve a new
  key (its intent row is read at delete time).

  All filesystem access goes through the configured `Cinder.Library.Filesystem`.
  """
  import Ecto.Query

  alias Cinder.Audit
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog.{Episode, Grab, Movie}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Library
  alias Cinder.Library.Deletion
  alias Cinder.Repo
  alias Cinder.Settings
  alias Cinder.Subtitles.Moviehash

  require Logger

  @type class :: :empty | :library_copy | :unmatched
  @type hold :: :recent | :symlink | :irregular | :unreadable | :too_large
  @type folder :: %{
          path: String.t(),
          name: String.t(),
          key: String.t(),
          root: String.t(),
          size: non_neg_integer(),
          class: class() | nil,
          hold: hold() | nil
        }

  # The classes the bulk "clear" may remove; `:unmatched` needs a per-folder confirmation.
  @safe_classes [:empty, :library_copy]
  @recent_seconds 3600
  @max_entries 100_000
  @max_depth 32

  @doc "The classes that may be cleared in bulk."
  @spec safe_classes() :: [class()]
  def safe_classes, do: @safe_classes

  @doc """
  Surveys every explicit import root for unreferenced job folders.

  Returns `{:ok, %{folders: folders, referenced: count}}` (`referenced` is how many job folders
  were skipped as still in use), or an error: `:import_roots_not_explicit`,
  `{:root_unreadable, root, reason}` or `{:client_list_failed, protocol, reason}`.
  """
  @spec scan() :: {:ok, %{folders: [folder()], referenced: non_neg_integer()}} | {:error, term()}
  def scan do
    with {:ok, roots} <- explicit_roots(),
         {:ok, client_keys} <- client_keys(),
         {:ok, candidates} <- candidates(roots) do
      refs = references()

      {referenced, unreferenced} =
        Enum.split_with(candidates, &referenced?(&1.key, client_keys, refs))

      {:ok, %{folders: classify_all(unreferenced), referenced: length(referenced)}}
    end
  end

  @doc """
  Deletes the job folders at `paths`, each only if — checked again right now — it is still a
  direct child of an explicit import root named `<title>.cinder-<key>`, is unreferenced, is not
  held, and has a class in `allowed`.

  Returns `{:ok, %{cleared: paths, skipped: [{path, reason}]}}`, or the same fail-closed errors
  as `scan/0` (nothing is deleted then). Each cleared folder writes an `admin_audit` row
  (`clear_download_folder`, entity `{"DownloadFolder", nil}`, detail `path`/`key`/`class`/`size`)
  attributed to `actor`. Skip reasons: `:not_a_job_folder`, `:gone`,
  `:referenced`, `{:held, hold}`, `{:class, class}` and `{:delete_failed, reason}` (logged).
  """
  @spec clear([String.t()], [class()], Cinder.Accounts.User.t() | nil) ::
          {:ok, %{cleared: [String.t()], skipped: [{String.t(), term()}]}} | {:error, term()}
  def clear(paths, allowed, actor) when is_list(paths) and is_list(allowed) do
    with {:ok, roots} <- explicit_roots(),
         {:ok, client_keys} <- client_keys() do
      {outcomes, _state} =
        Enum.map_reduce(paths, %{index: nil, cache: %{}}, fn path, state ->
          clear_one(path, allowed, {roots, client_keys}, actor, state)
        end)

      {:ok,
       %{
         cleared: for({path, :ok} <- outcomes, do: path),
         skipped: for({path, {:skip, reason}} <- outcomes, do: {path, reason})
       }}
    end
  end

  defp clear_one(path, allowed, {roots, client_keys}, actor, state) do
    case job_folder(path, roots) do
      {:ok, folder} -> clear_folder(folder, allowed, client_keys, actor, state)
      {:skip, reason} -> {{path, {:skip, reason}}, state}
    end
  end

  defp clear_folder(folder, allowed, client_keys, actor, state) do
    case survey_and_classify(folder, state) do
      {:ok, classified, state} ->
        {guarded_delete(classified, allowed, client_keys, actor), state}

      {:skip, reason} ->
        {{folder.path, {:skip, reason}}, state}
    end
  end

  # The reference check sits immediately before the delete: it is the one that must not be stale.
  defp guarded_delete(folder, allowed, client_keys, actor) do
    with :ok <- check_class(folder, allowed),
         :ok <- check_unreferenced(folder, client_keys),
         :ok <- delete(folder) do
      Logger.info("orphan download folder cleared: #{folder.path} (#{folder.class})")
      audit_cleared(actor, folder)
      {folder.path, :ok}
    else
      {:skip, {:delete_failed, reason} = skip} ->
        Logger.warning("orphan download folder not deleted: #{folder.path}: #{inspect(reason)}")
        {folder.path, {:skip, skip}}

      {:skip, reason} ->
        {folder.path, {:skip, reason}}
    end
  end

  # Written after the delete, like `Catalog.audit_deletion/5`: the folder is gone either way, so a
  # failed audit write is logged, never propagated.
  defp audit_cleared(actor, folder) do
    detail = %{path: folder.path, key: folder.key, class: folder.class, size: folder.size}

    case Audit.log(actor, :clear_download_folder, {"DownloadFolder", nil}, detail) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "clear_download_folder audit row failed for #{folder.path}: " <>
            inspect(changeset.errors)
        )
    end
  end

  defp job_folder(path, roots) when is_binary(path) do
    expanded = Path.expand(path)
    root = Path.dirname(expanded)
    name = Path.basename(expanded)

    with true <- root in roots,
         {:ok, key} <- Deletion.job_folder_key(name) do
      case fs().lstat(expanded) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, folder(root, name, key)}
        {:error, :enoent} -> {:skip, :gone}
        _other -> {:skip, :not_a_job_folder}
      end
    else
      _ -> {:skip, :not_a_job_folder}
    end
  end

  defp job_folder(_path, _roots), do: {:skip, :not_a_job_folder}

  defp folder(root, name, key) do
    %{
      path: Path.join(root, name),
      name: name,
      key: String.downcase(key),
      root: root,
      size: 0,
      class: nil,
      hold: nil
    }
  end

  defp survey_and_classify(folder, state) do
    surveyed = survey(folder, System.os_time(:second))

    case surveyed do
      %{hold: nil, files: files} ->
        state = ensure_index(state, files)
        {class, cache} = classify_files(files, state.index, state.cache)
        {:ok, %{surveyed | class: class}, %{state | cache: cache}}

      %{hold: hold} ->
        {:skip, {:held, hold}}
    end
  end

  # The library index is only worth building (one `lstat` per library file) when a folder holds a
  # video to compare; it is then kept for the rest of the call.
  defp ensure_index(%{index: nil} = state, files),
    do: if(Enum.any?(files, &video?/1), do: %{state | index: library_index()}, else: state)

  defp ensure_index(state, _files), do: state

  defp check_class(%{class: class}, allowed) do
    if class in allowed, do: :ok, else: {:skip, {:class, class}}
  end

  defp check_unreferenced(folder, client_keys) do
    if referenced?(folder.key, client_keys, references()), do: {:skip, :referenced}, else: :ok
  end

  defp delete(folder) do
    case Library.delete_download_source(folder.path) do
      :ok -> :ok
      {:error, reason} -> {:skip, {:delete_failed, reason}}
    end
  end

  ## Discovery

  defp explicit_roots do
    case Settings.explicit_import_roots() do
      roots when is_list(roots) and roots != [] -> {:ok, Enum.map(roots, &Path.expand/1)}
      _unset -> {:error, :import_roots_not_explicit}
    end
  end

  defp candidates(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case root_candidates(root) do
        {:ok, found} -> {:cont, {:ok, acc ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp root_candidates(root) do
    case fs().ls(root) do
      {:ok, names} ->
        {:ok, names |> Enum.sort() |> Enum.map(&candidate(root, &1)) |> Enum.reject(&is_nil/1)}

      {:error, reason} ->
        {:error, {:root_unreadable, root, reason}}
    end
  end

  defp candidate(root, name) do
    with {:ok, key} <- Deletion.job_folder_key(name),
         {:ok, %File.Stat{type: :directory}} <- fs().lstat(Path.join(root, name)) do
      folder(root, name, key)
    else
      _ -> nil
    end
  end

  ## References

  defp client_keys do
    Enum.reduce_while(Download.available_protocols(), {:ok, MapSet.new()}, fn protocol,
                                                                              {:ok, keys} ->
      case list_managed(protocol) do
        {:ok, entries} ->
          {:cont, {:ok, Enum.reduce(entries, keys, &put_operation_key/2)}}

        {:error, reason} ->
          {:halt, {:error, {:client_list_failed, protocol, reason}}}
      end
    end)
  end

  defp put_operation_key(%{operation_key: key}, keys) when is_binary(key),
    do: MapSet.put(keys, String.downcase(key))

  defp put_operation_key(_entry, keys), do: keys

  # `health/0` first: SABnzbd answers a bad API key with HTTP 200, which `list_managed/0` reads as
  # an empty list. A client that is not healthy cannot vouch for what it does not list.
  defp list_managed(protocol) do
    case Download.client_for(protocol) do
      {:ok, client} ->
        case client.health() do
          {:error, reason} ->
            Logger.warning(
              "#{protocol} download client is unhealthy, download folders refused: #{inspect(reason)}"
            )

            {:error, {:unhealthy, reason}}

          _ok_or_warning ->
            client.list_managed()
        end

      :error ->
        {:error, :not_configured}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Lowercased once, so a per-folder check is a plain `contains?` per path.
  defp references do
    paths = content_paths() ++ library_paths() ++ Repo.all(from f in BookFile, select: f.path)

    %{
      intent_keys:
        MapSet.new(Repo.all(from i in Intent, select: i.operation_key), &String.downcase/1),
      paths: for(path <- paths, is_binary(path), do: String.downcase(path))
    }
  end

  defp referenced?(key, client_keys, %{intent_keys: intent_keys, paths: paths}) do
    MapSet.member?(client_keys, key) or MapSet.member?(intent_keys, key) or
      Enum.any?(paths, &String.contains?(&1, key))
  end

  defp content_paths do
    Repo.all(from g in Grab, where: not is_nil(g.content_path), select: g.content_path) ++
      Repo.all(from m in Movie, where: not is_nil(m.content_path), select: m.content_path) ++
      Repo.all(from g in BookGrab, where: not is_nil(g.content_path), select: g.content_path)
  end

  # The movie and episode files the library holds, the candidates a download copy is compared
  # against. Book and audiobook files are only counted as references (`references/0`): a video is
  # never one of them.
  defp library_paths do
    movies = Repo.all(from m in Movie, select: {m.file_path, m.part_file_paths})
    episodes = Repo.all(from e in Episode, select: {e.file_path, e.part_file_paths})

    for {file_path, part_paths} <- movies ++ episodes,
        path <- [file_path | List.wrap(part_paths)],
        is_binary(path),
        do: path
  end

  ## Survey

  defp survey(folder, now) do
    case walk(folder.path, 0, %{files: [], recent?: false, count: 0}, now) do
      {:ok, %{files: files, recent?: recent?}} ->
        Map.merge(folder, %{
          files: files,
          hold: if(recent?, do: :recent),
          size: files |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        })

      {:error, hold} ->
        Map.merge(folder, %{files: [], hold: hold})
    end
  end

  defp walk(_dir, depth, _acc, _now) when depth > @max_depth, do: {:error, :too_large}

  defp walk(dir, depth, acc, now) do
    case fs().ls(dir) do
      {:ok, names} -> Enum.reduce_while(names, {:ok, acc}, &walk_entry(&1, dir, depth, now, &2))
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp walk_entry(_name, _dir, _depth, _now, {:ok, %{count: count}}) when count >= @max_entries,
    do: {:halt, {:error, :too_large}}

  defp walk_entry(name, dir, depth, now, {:ok, acc}) do
    path = Path.join(dir, name)
    acc = %{acc | count: acc.count + 1}

    case fs().lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} ->
        {:cont,
         {:ok,
          %{acc | files: [{path, size} | acc.files], recent?: acc.recent? or recent?(stat, now)}}}

      {:ok, %File.Stat{type: :directory} = stat} ->
        acc = %{acc | recent?: acc.recent? or recent?(stat, now)}
        continue_or_halt(walk(path, depth + 1, acc, now))

      {:ok, %File.Stat{type: :symlink}} ->
        {:halt, {:error, :symlink}}

      {:ok, _other} ->
        {:halt, {:error, :irregular}}

      {:error, _reason} ->
        {:halt, {:error, :unreadable}}
    end
  end

  defp continue_or_halt({:ok, _acc} = ok), do: {:cont, ok}
  defp continue_or_halt({:error, _reason} = error), do: {:halt, error}

  # A missing mtime is unknown, so it counts as recent (the fail-safe side); a future one does too.
  defp recent?(%File.Stat{mtime: mtime}, now) do
    case unix(mtime) do
      nil -> true
      seconds -> seconds >= now - @recent_seconds
    end
  end

  defp unix(seconds) when is_integer(seconds), do: seconds

  defp unix({{_, _, _}, {_, _, _}} = datetime),
    do:
      datetime
      |> NaiveDateTime.from_erl!()
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.to_unix()

  defp unix(_unknown), do: nil

  ## Classification

  defp classify_all(candidates) do
    now = System.os_time(:second)
    surveyed = Enum.map(candidates, &survey(&1, now))
    state = Enum.reduce(surveyed, %{index: nil, cache: %{}}, &ensure_index_for(&1, &2))

    {folders, _state} =
      Enum.map_reduce(surveyed, state, fn
        %{hold: nil, files: files} = folder, state ->
          {class, cache} = classify_files(files, state.index, state.cache)
          {Map.delete(%{folder | class: class}, :files), %{state | cache: cache}}

        folder, state ->
          {Map.delete(folder, :files), state}
      end)

    Enum.sort_by(folders, &{class_rank(&1.class), -&1.size, &1.name})
  end

  defp ensure_index_for(%{hold: nil, files: files}, state), do: ensure_index(state, files)
  defp ensure_index_for(_held, state), do: state

  defp class_rank(:empty), do: 0
  defp class_rank(:library_copy), do: 1
  defp class_rank(:unmatched), do: 2
  defp class_rank(nil), do: 3

  defp classify_files([], _index, cache), do: {:empty, cache}

  defp classify_files(files, index, cache) do
    case Enum.filter(files, &video?/1) do
      [] -> {:unmatched, cache}
      videos -> classify_videos(videos, index, cache)
    end
  end

  defp classify_videos(videos, index, cache) do
    Enum.reduce_while(videos, {:library_copy, cache}, fn video, {class, cache} ->
      case library_match?(video, index, cache) do
        {true, cache} -> {:cont, {class, cache}}
        {false, cache} -> {:halt, {:unmatched, cache}}
      end
    end)
  end

  defp video?({path, _size}), do: Library.video_file?(path)

  defp library_match?({path, size}, index, cache) do
    case Map.get(index, size) do
      nil -> {false, cache}
      candidates -> hashed_match?(path, candidates, cache)
    end
  end

  defp hashed_match?(path, candidates, cache) do
    case hash_of(path, cache) do
      {{:ok, hash}, cache} -> any_candidate?(candidates, hash, cache)
      {_unhashable, cache} -> {false, cache}
    end
  end

  defp any_candidate?(candidates, hash, cache) do
    Enum.reduce_while(candidates, {false, cache}, fn candidate, {_found, cache} ->
      case hash_of(candidate, cache) do
        {{:ok, ^hash}, cache} -> {:halt, {true, cache}}
        {_other, cache} -> {:cont, {false, cache}}
      end
    end)
  end

  # A file under 128 KiB (`:too_small`) or an unreadable one has no moviehash, so it never matches.
  defp hash_of(path, cache) do
    case cache do
      %{^path => result} ->
        {result, cache}

      _ ->
        result = Moviehash.of_file(path)
        {result, Map.put(cache, path, result)}
    end
  end

  defp library_index do
    Enum.reduce(Enum.uniq(library_paths()), %{}, fn path, index ->
      case fs().lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          Map.update(index, size, [path], &[path | &1])

        _missing_or_irregular ->
          index
      end
    end)
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
