defmodule Cinder.Library.Backfill do
  @moduledoc """
  One-time media-info backfill for media imported before the feature landed, and for a row whose
  sidecars went unregistered because import adopted an already-present file (issue #128). Probes
  each `:available` movie / filed episode and scans for present sidecars, writing the
  `imported_*` language columns and re-registering those sidecars in the subtitle manifest as
  Cinder-managed. Idempotent. Cannot recover sidecars that pre-feature imports left in the
  download folder (only the video was hardlinked then) — reports embedded tracks + whatever
  `.srt` currently sits next to the file.
  """
  require Logger
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Library.{ImportedQuality, Sidecars}
  alias Cinder.Repo
  alias Cinder.Subtitles

  def run do
    movies = Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
    episodes = Repo.all(from e in Episode, where: not is_nil(e.file_path))
    Enum.each(movies ++ episodes, &backfill_one/1)
  end

  defp backfill_one(record) do
    case Catalog.set_media_info(record, ImportedQuality.recapture(record)) do
      {:ok, _} ->
        Enum.each(file_paths(record), fn path ->
          languages = path |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
          Subtitles.mark_release_sidecars(path, languages)
        end)

        :ok

      {:error, e} ->
        Logger.warning("backfill failed for #{record.file_path}: #{inspect(e)}")
    end
  end

  defp file_paths(%Episode{} = episode), do: Episode.file_paths(episode)
  defp file_paths(%Movie{} = movie), do: Movie.file_paths(movie)
end
