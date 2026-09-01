defmodule Cinder.Catalog.LibraryVisibility do
  @moduledoc """
  Read-side report of catalog rows a media server's own directory walk would silently skip.
  Carved out of `Cinder.Catalog` as plain code motion — `dot_folder_files/0` is re-exported
  unchanged via `defdelegate` in `Cinder.Catalog`.
  """
  import Ecto.Query

  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Repo

  @doc """
  Every movie/episode file (primary AND part) whose stored path has a dot-prefixed component
  (#399) — Jellyfin/Plex skip dot-directories while scanning, so a title imported before
  `Cinder.Library.Naming`'s guard existed can sit `:available` and still be invisible with
  nothing reporting why. `/settings` surfaces this list so an operator can decide whether to
  rename the folder by hand; nothing here moves a file or rewrites a row.

  One row per offending PATH, not per movie/episode: a multi-part row (`part_file_paths`) can in
  principle have parts under different folders, and an operator deciding what to rename needs
  every affected file named, not just the first one found. `file_path`/`part_file_paths` are read
  through `Movie.file_paths/1`/`Episode.file_paths/1` — the same accessor
  `Cinder.Library.Adoption.managed_paths/0` already uses for "all of this row's real files" — so
  a `nil` primary with an offending part is still caught, and a clean primary never hides an
  offending part.

  Reads only the already-stored `file_path`/`part_file_paths` columns — no filesystem walk, unlike
  `Cinder.Library.Adoption.scan/0`. Bounded by catalog size (a household library), so this runs
  fresh on every `/settings` load rather than needing a cache or a scheduled job.
  """
  @spec dot_folder_files() :: [
          %{kind: :movie | :episode, id: integer(), title: String.t(), file_path: String.t()}
        ]
  def dot_folder_files do
    dot_folder_movies() ++ dot_folder_episodes()
  end

  defp dot_folder_movies do
    Repo.all(from(m in Movie))
    |> Enum.flat_map(fn movie ->
      movie
      |> Movie.file_paths()
      |> Enum.filter(&dot_folder_path?/1)
      |> Enum.map(&%{kind: :movie, id: movie.id, title: movie.title, file_path: &1})
    end)
  end

  defp dot_folder_episodes do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        join: sr in assoc(s, :series),
        select: {e, sr.title, s.season_number}
    )
    |> Enum.flat_map(fn {episode, series_title, season_number} ->
      code = Episode.codes_label(season_number, [episode.episode_number])
      title = "#{series_title} #{code}"

      episode
      |> Episode.file_paths()
      |> Enum.filter(&dot_folder_path?/1)
      |> Enum.map(&%{kind: :episode, id: episode.id, title: title, file_path: &1})
    end)
  end

  defp dot_folder_path?(path),
    do: path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
end
