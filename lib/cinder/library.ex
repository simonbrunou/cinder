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

  alias Cinder.Catalog.Movie

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)
  @illegal ~r/[\/\\:*?"<>|]/

  @doc """
  Hardlinks `movie`'s downloaded file into the library and triggers a scan.
  Returns `{:ok, dest_path}` or `{:error, reason}`. Idempotent: a dest that
  already exists (`:eexist`) is treated as success.
  """
  @spec import_movie(Movie.t()) :: {:ok, String.t()} | {:error, term()}
  def import_movie(%Movie{file_path: path}) when path in [nil, ""], do: {:error, :no_file_path}

  def import_movie(%Movie{} = movie) do
    with {:ok, source} <- resolve_source(movie.file_path),
         dest = build_dest(movie, source),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         :ok <- link(source, dest),
         :ok <- media_server().scan() do
      {:ok, dest}
    end
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
