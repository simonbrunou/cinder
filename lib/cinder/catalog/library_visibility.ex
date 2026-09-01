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
  Movies and episodes whose stored `file_path` has a dot-prefixed path component (#399) —
  Jellyfin/Plex skip dot-directories while scanning, so a title imported before
  `Cinder.Library.Naming`'s guard existed can sit `:available` and still be invisible with
  nothing reporting why. `/settings` surfaces this list so an operator can decide whether to
  rename the folder by hand; nothing here moves a file or rewrites a row.

  Reads only the already-stored `file_path` columns — no filesystem walk, unlike
  `Cinder.Library.Adoption.scan/0`. Bounded by catalog size (a household library), so this runs
  fresh on every `/settings` load rather than needing a cache or a scheduled job.
  """
  @spec dot_folder_files() :: [
          %{kind: :movie | :episode, id: integer(), title: String.t(), file_path: String.t()}
        ]
  def dot_folder_files do
    Enum.filter(dot_folder_movies() ++ dot_folder_episodes(), &dot_folder_path?(&1.file_path))
  end

  defp dot_folder_movies do
    Repo.all(
      from m in Movie,
        where: not is_nil(m.file_path),
        select: %{kind: :movie, id: m.id, title: m.title, file_path: m.file_path}
    )
  end

  defp dot_folder_episodes do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        join: sr in assoc(s, :series),
        where: not is_nil(e.file_path),
        select: %{
          id: e.id,
          file_path: e.file_path,
          series_title: sr.title,
          season_number: s.season_number,
          episode_number: e.episode_number
        }
    )
    |> Enum.map(fn row ->
      code = Episode.codes_label(row.season_number, [row.episode_number])

      %{
        kind: :episode,
        id: row.id,
        title: "#{row.series_title} #{code}",
        file_path: row.file_path
      }
    end)
  end

  defp dot_folder_path?(path),
    do: path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
end
