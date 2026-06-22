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
    with {:ok, source} <- resolve_source(movie.file_path),
         dest = build_dest(movie, source),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         :ok <- link(source, dest) do
      scan(dest)
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
    with {:ok, videos} <- video_files(content_path) do
      {to_import, unmatched} = videos |> match_episodes(episodes) |> resolve(videos, episodes)

      case link_all(to_import) do
        {:ok, []} ->
          # Nothing mapped — still surface the offending file names (don't silently drop them)
          # so a parser gap on a real release is diagnosable; the poller parks the grab.
          log_unmatched(unmatched)
          {:ok, [], unmatched}

        {:ok, imported} ->
          log_unmatched(unmatched)
          scan(content_path)
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

  # {episode, source_path} pairs for files that name a specific episode in the grab (a
  # double-episode file yields two pairs — the same source hardlinked under both names).
  defp match_episodes(videos, episodes) do
    for {path, _size} <- videos,
        parsed = Parser.parse(Path.basename(path)),
        not is_nil(parsed.episodes),
        ep <- episodes,
        ep.season.season_number == parsed.season,
        ep.episode_number in parsed.episodes,
        do: {ep, path}
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
  defp link_all(to_import) do
    Enum.reduce_while(to_import, {:ok, []}, fn {ep, source}, {:ok, acc} ->
      dest = build_episode_dest(ep, source)

      with :ok <- fs().mkdir_p(Path.dirname(dest)),
           :ok <- link(source, dest) do
        {:cont, {:ok, [{ep.id, dest} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp build_episode_dest(%Episode{season: season} = ep, source) do
    show = library_name(sanitize(season.series.title), season.series.year, season.series.tmdb_id)
    code = "S#{pad(season.season_number)}E#{pad(ep.episode_number)}"

    Path.join([
      library_path(),
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
  defp scan(dest) do
    case media_server().scan() do
      {:error, reason} -> log_scan_failure(dest, reason)
      _ -> :ok
    end
  rescue
    e -> log_scan_failure(dest, e)
  catch
    kind, value -> log_scan_failure(dest, {kind, value})
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

  defp build_dest(%Movie{title: title, year: year, tmdb_id: tmdb_id}, source) do
    name = library_name(sanitize(title), year, tmdb_id)
    Path.join([library_path(), name, name <> Path.extname(source)])
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
  end

  # ponytail: hardlink only; library must share the downloads' filesystem (see spec).
  defp link(source, dest) do
    case fs().ln(source, dest) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp media_server, do: Application.fetch_env!(:cinder, :media_server)
  defp library_path, do: Application.fetch_env!(:cinder, :library_path)
end
