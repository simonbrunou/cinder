defmodule Cinder.Library do
  @moduledoc """
  Import: hardlink a completed download into the Jellyfin library, renamed to
  `Title (Year)/Title (Year).ext` (or bare `Title` when the year is unknown, or
  `tmdb-<id>` when the title has no usable characters), then trigger a scan.

  Filesystem ops and the media server are reached only through behaviours
  (`Cinder.Library.Filesystem`, `Cinder.Library.MediaServer`), resolved from
  config at runtime so tests use Mox mocks and never touch disk or the network.
  Owns filesystem + Jellyfin only — `Catalog` remains the status choke-point.
  """

  require Logger

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog.{Episode, Movie}

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)
  @illegal ~r/[\/\\:*?"<>|]/

  # The library kinds Cinder manages. The single source of truth — config keys
  # (`:"#{kind}_library_path"`, the per-kind Plex section, the size band), the
  # settings UI, health checks, and the media-server scan all derive from it, so a
  # new media type (e.g. `:books`) is one entry here, not a fork. Pure literal:
  # read at boot and at config-eval time, so it must not touch Application env or Repo.
  @kinds [:movies, :tv]

  @doc "The library kinds Cinder manages (e.g. `:movies`, `:tv`)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Hardlinks `movie`'s downloaded file into the library and triggers a scan.
  Returns `{:ok, dest_path}` or `{:error, reason}`. Idempotent: a dest that
  already exists (`:eexist`) is treated as success. The scan is best-effort —
  once the file is hardlinked the import has succeeded, so a failing scan is
  logged but does not turn into `{:error, _}`.
  """
  @spec import_movie(Movie.t()) :: {:ok, String.t()} | {:error, term()}
  def import_movie(%Movie{file_path: path}) when path in [nil, ""], do: {:error, :no_file_path}

  def import_movie(%Movie{} = movie) do
    with {:ok, root} <- root(:movies),
         {:ok, source} <- resolve_source(movie.file_path),
         dest = build_dest(movie, source, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         :ok <- link(source, dest) do
      scan(:movies, dest)
      {:ok, dest}
    end
  end

  @doc """
  Imports the video files at `content_path` for `episodes` (a grab's episodes, each preloaded
  `season: :series`). Returns `{:ok, imported, unmatched}` — `imported` is
  `[{episode_id, dest_path}]`, `unmatched` the video files that mapped to no episode (logged,
  not an error: graceful park) — or `{:error, reason}` on a transient filesystem error (the grab
  retries). One best-effort scan fires when anything imported.

  Layout: `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`. Files are matched by parsing `SxxEyy`
  from each name and intersecting with the grab's episodes (a double-episode file maps to both).
  For a single-episode grab whose files name no specific episode, the largest video is assigned
  to it — mirroring `import_movie`'s sample-skipping largest-wins, since the grab already names
  the one episode. Reuses `import_movie`'s `link`/`scan`/naming primitives.
  """
  @spec import_episodes(String.t() | nil, [Episode.t()]) ::
          {:ok, [{integer(), String.t()}], [String.t()]} | {:error, term()}
  def import_episodes(content_path, _episodes) when content_path in [nil, ""],
    do: {:error, :no_content_path}

  def import_episodes(content_path, episodes) do
    # Strict separate TV root: with no :tv_library_path configured, return an error tuple so the
    # poller holds the grab (no bump, no park) until it's set, rather than raising every tick
    # (a raise would sit above the poller's {:error,_} clause and re-raise — see TvPoller). The
    # same guard (`root/1`) protects the movie path symmetrically.
    with {:ok, root} <- root(:tv) do
      do_import_episodes(content_path, episodes, root)
    end
  end

  defp do_import_episodes(content_path, episodes, root) do
    with {:ok, videos} <- video_files(content_path) do
      {to_import, unmatched} =
        videos |> match_episodes(episodes) |> dedupe_per_episode() |> resolve(videos, episodes)

      case link_all(to_import, root) do
        {:ok, []} ->
          # Nothing mapped — still surface the offending file names (don't silently drop them)
          # so a parser gap on a real release is diagnosable; the poller parks the grab.
          log_unmatched(unmatched)
          {:ok, [], unmatched}

        {:ok, imported} ->
          log_unmatched(unmatched)
          scan(:tv, content_path)
          {:ok, imported, unmatched}

        {:error, _reason} = err ->
          err
      end
    end
  end

  # All video files under content_path: the folder's video files for a pack/multi-file download,
  # or the lone file itself for a single-file one (size 0 — it's the only candidate).
  defp video_files(path) do
    if fs().dir?(path) do
      with {:ok, files} <- fs().find_files(path), do: {:ok, only_videos(files)}
    else
      {:ok, only_videos([{path, 0}])}
    end
  end

  defp only_videos(files),
    do: Enum.filter(files, fn {p, _size} -> String.downcase(Path.extname(p)) in @video_exts end)

  # {episode, source_path, size} triples for files that name a specific episode in the grab (a
  # double-episode file yields two — the same source hardlinked under both names).
  defp match_episodes(videos, episodes) do
    for {path, size} <- videos,
        parsed = Parser.parse(Path.basename(path)),
        not is_nil(parsed.episodes),
        ep <- episodes,
        ep.season.season_number == parsed.season,
        ep.episode_number in parsed.episodes,
        do: {ep, path, size}
  end

  # One source per episode: when two files parse the same SxxEyy, keep the largest (path breaks
  # ties for a dest stable across retries) and let the losers fall through to `resolve` as
  # unmatched (logged) — never link two different sources onto one episode's dest (the second
  # would collide). Group by episode, not source, so a double-episode file still maps to both.
  defp dedupe_per_episode(matches) do
    matches
    |> Enum.group_by(fn {ep, _path, _size} -> ep.id end)
    |> Enum.map(fn {_id, group} ->
      {ep, path, _size} = Enum.max_by(group, fn {_ep, path, size} -> {size, path} end)
      {ep, path}
    end)
  end

  # Decide the import set + the leftover (unmatched) video files for logging.
  defp resolve([], videos, episodes) do
    if single_ep_fallback?(episodes, videos) do
      # Largest wins (skips samples/extras); path breaks ties so the dest is stable across retries.
      {path, _size} = Enum.max_by(videos, fn {p, size} -> {size, p} end)
      {[{hd(episodes), path}], paths(videos) -- [path]}
    else
      {[], paths(videos)}
    end
  end

  defp resolve(matched, videos, _episodes) do
    matched_paths = matched |> Enum.map(fn {_ep, p} -> p end) |> MapSet.new()
    {matched, Enum.reject(paths(videos), &MapSet.member?(matched_paths, &1))}
  end

  # Fall back to largest-wins only for a lone-episode grab whose files name NO specific episode
  # (so we never mistake a clearly-numbered other episode for ours).
  defp single_ep_fallback?([_one], [_ | _] = videos),
    do: Enum.all?(videos, fn {p, _size} -> is_nil(Parser.parse(Path.basename(p)).episodes) end)

  defp single_ep_fallback?(_episodes, _videos), do: false

  defp paths(videos), do: Enum.map(videos, fn {p, _size} -> p end)

  # Hardlink each match; a transient error halts and returns {:error, _} so the grab retries
  # the whole import next tick (already-linked files are :eexist ⇒ :ok, so it's idempotent).
  defp link_all(to_import, root) do
    Enum.reduce_while(to_import, {:ok, []}, fn {ep, source}, {:ok, acc} ->
      dest = build_episode_dest(ep, source, root)

      with :ok <- fs().mkdir_p(Path.dirname(dest)),
           :ok <- link(source, dest) do
        {:cont, {:ok, [{ep.id, dest} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp build_episode_dest(%Episode{season: season} = ep, source, root) do
    show = library_name(sanitize(season.series.title), season.series.year, season.series.tmdb_id)
    code = "S#{pad(season.season_number)}E#{pad(ep.episode_number)}"

    Path.join([
      root,
      show,
      "Season #{pad(season.season_number)}",
      "#{show} - #{code}#{Path.extname(source)}"
    ])
  end

  # Two-digit minimum, never truncated (episode/season can exceed 99 on long-running shows).
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp log_unmatched([]), do: :ok

  defp log_unmatched(paths) do
    Logger.warning("import skipped #{length(paths)} unmatched file(s): #{inspect(paths)}")
    :ok
  end

  # Best-effort: the file is already hardlinked into the library, so a failed scan —
  # an {:error, _} return OR a raise/exit from a misconfigured impl (e.g. a bad URL
  # deep in the HTTP stack) — must not strand a correctly-imported movie at
  # :import_failed. The media server picks it up on its next periodic scan. Log and
  # report the import as done.
  defp scan(kind, dest) do
    case media_server().scan(kind) do
      {:error, reason} -> log_scan_failure(dest, reason)
      _ -> :ok
    end
  rescue
    e -> log_scan_failure(dest, e)
  catch
    caught, value -> log_scan_failure(dest, {caught, value})
  end

  defp log_scan_failure(dest, reason) do
    Logger.warning("media-server scan failed after importing #{dest}: #{inspect(reason)}")
  end

  # content_path is a file for single-file torrents, a folder for multi-file ones.
  defp resolve_source(path) do
    if fs().dir?(path) do
      with {:ok, files} <- fs().find_files(path), do: pick_video(files)
    else
      {:ok, path}
    end
  end

  # Largest video file wins (skips samples/extras); lexicographic path breaks ties
  # so the choice — and therefore the dest — is stable across retries.
  defp pick_video(files) do
    files
    |> Enum.filter(fn {p, _size} -> String.downcase(Path.extname(p)) in @video_exts end)
    |> Enum.sort_by(fn {p, size} -> {-size, p} end)
    |> case do
      [{path, _size} | _] -> {:ok, path}
      [] -> {:error, :no_video_file}
    end
  end

  defp build_dest(%Movie{title: title, year: year, tmdb_id: tmdb_id}, source, root) do
    name = library_name(sanitize(title), year, tmdb_id)
    Path.join([root, name, name <> Path.extname(source)])
  end

  # Jellyfin's scheme is `Title (Year)`; with no year (a TMDB entry lacking a
  # release date) fall back to a bare `Title`, and if the title sanitizes to
  # nothing (all-illegal characters) fall back to a tmdb id so the file lands in
  # its own folder rather than the library root.
  defp library_name("", _year, tmdb_id), do: "tmdb-#{tmdb_id}"
  defp library_name(title, nil, _tmdb_id), do: title
  defp library_name(title, year, _tmdb_id), do: "#{title} (#{year})"

  # Strip filesystem-illegal characters, then trim surrounding whitespace so a
  # title that is blank after sanitizing collapses to "" and hits the tmdb-id
  # fallback rather than producing a whitespace-named folder.
  defp sanitize(title) do
    title
    |> String.replace(@illegal, "")
    |> String.trim()
    |> reject_dot_only()
  end

  # A name that is only dots (".", "..", …) would become a path segment that escapes the library
  # root (`Path.join([root, "..", …])`). Collapse it to "" so library_name falls back to the
  # tmdb-id folder, same as an all-illegal title.
  defp reject_dot_only(name), do: if(name =~ ~r/\A\.+\z/, do: "", else: name)

  # ponytail: hardlink only; library must share the downloads' filesystem (see spec).
  defp link(source, dest) do
    case fs().ln(source, dest) do
      :ok -> :ok
      {:error, :eexist} -> idempotent_or_collision(source, dest)
      {:error, _reason} = err -> err
    end
  end

  # An existing dest is the idempotent re-import case ONLY if it's already a hardlink of source
  # (same inode). A *different* inode means another title collided on the same `Title (Year)` name
  # — fail (the item parks) rather than silently claim the other movie/episode's file as this one's.
  defp idempotent_or_collision(source, dest) do
    with {:ok, %{inode: si}} <- fs().lstat(source),
         {:ok, %{inode: di}} <- fs().lstat(dest),
         true <- si == di do
      :ok
    else
      _ -> {:error, :dest_exists}
    end
  end

  @doc """
  Deletes one imported library file and prunes the folders it leaves empty.

  Idempotent: a `nil`/blank path or an already-missing file is `:ok`. After unlinking, empty
  parent directories are removed walking up, stopping at (never removing) the configured library
  root — so a `Title (Year)/` or `Season NN/`→show folder disappears when it empties, but the root
  and any non-empty or out-of-library directory are untouched. A real unlink error (e.g. `:eacces`)
  is surfaced and nothing is pruned. Hardlink note: this frees disk space only once the download
  client also drops its copy. (A path that `Path.expand` can't place strictly inside a root —
  relative, `..`-laden, or a symlinked root — fails CLOSED: the file is unlinked but no folder is
  pruned. Safe-by-default for a destructive op; a symlinked root may leave empty folders behind —
  do NOT "fix" this with `File.read_link`/realpath, which would widen the deletion surface.)
  """
  @spec delete_file(String.t() | nil) :: :ok | {:error, term()}
  def delete_file(path) when path in [nil, ""], do: :ok

  def delete_file(path) do
    case fs().rm(path) do
      :ok -> prune_empty_dirs(Path.dirname(path))
      {:error, :enoent} -> prune_empty_dirs(Path.dirname(path))
      {:error, _reason} = err -> err
    end
  end

  # Remove `dir` if it is empty and strictly inside a library root, then recurse to its parent.
  # `fs().rmdir/1` only removes an empty dir, so a non-empty parent returns an error and halts the
  # walk. Always returns :ok — pruning is best-effort cleanup, never the operation's success signal.
  defp prune_empty_dirs(dir) do
    if prunable?(dir) do
      case fs().rmdir(dir) do
        :ok -> prune_empty_dirs(Path.dirname(dir))
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  # Prunable only when `dir` sits strictly inside a configured library root (never the root itself,
  # never a path outside any root) — so a misconfigured/old file_path can never rmdir outside the
  # library or delete a root. Split into a flat helper to keep credo Refactor.Nesting happy.
  defp prunable?(dir) do
    expanded = Path.expand(dir)
    Enum.any?(@kinds, &prunable_under_kind?(expanded, &1))
  end

  defp prunable_under_kind?(expanded, kind) do
    case root(kind) do
      {:ok, r} ->
        r = Path.expand(r)
        expanded != r and String.starts_with?(expanded <> "/", r <> "/")

      _ ->
        false
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp media_server, do: Application.fetch_env!(:cinder, :media_server)

  # The configured import root for a kind, or {:error, :library_not_configured} when unset/blank —
  # used by both importers so an unconfigured root holds (poller retries) instead of raising. The
  # same shape for every kind: movies and TV are no longer special-cased.
  defp root(kind) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :library_not_configured}
    end
  end
end
