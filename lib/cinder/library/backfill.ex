defmodule Cinder.Library.Backfill do
  @moduledoc """
  One-time media-info backfill for media imported before the feature landed, and for a row whose
  sidecars went unregistered because import adopted an already-present file (issue #128). Probes
  each `:available` movie / filed episode and scans for present sidecars, writing the
  `imported_*` language columns. Idempotent. Cannot recover sidecars that pre-feature imports
  left in the download folder (only the video was hardlinked then) — reports embedded tracks +
  whatever `.srt` currently sits next to the file.

  It also marks a canonical `<video>.<lang>.srt` it finds as Cinder-managed in the subtitle
  manifest (`Cinder.Subtitles.mark_release_sidecars/3`), by default only in a language the
  manifest already tracks, so a subtitle the user put next to the video in an untracked language
  stays theirs (#993). The
  `register_untracked: true` opt-in of `run/1` takes an untracked language too, the #128 repair.
  """
  require Logger
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Library.{ImportedQuality, Sidecars}
  alias Cinder.Repo
  alias Cinder.Subtitles

  @doc """
  Backfills every `:available` movie with a file and every episode with a file.

  `register_untracked: true` also registers a canonical sidecar in a language the subtitle
  manifest does not track, for a row imported before Cinder recorded its sidecars. Cinder cannot
  tell such a sidecar from a subtitle you put next to the video yourself, so a hand-placed
  subtitle can become managed with it, and the next subtitle fetch for a wanted language may
  replace it. `Cinder.Subtitles.hand_back/2` gives one back.
  """
  @spec run(register_untracked: boolean()) :: :ok
  def run(opts \\ []) do
    opts = Keyword.validate!(opts, register_untracked: false)
    movies = Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
    episodes = Repo.all(from e in Episode, where: not is_nil(e.file_path))
    Enum.each(movies ++ episodes, &backfill_one(&1, opts))
  end

  defp backfill_one(record, opts) do
    case Catalog.set_media_info(record, ImportedQuality.recapture(record)) do
      {:ok, _} ->
        Enum.each(file_paths(record), fn path ->
          languages = path |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
          Subtitles.mark_release_sidecars(path, languages, opts)
        end)

        :ok

      {:error, e} ->
        Logger.warning("backfill failed for #{record.file_path}: #{inspect(e)}")
    end
  end

  defp file_paths(%Episode{} = episode), do: Episode.file_paths(episode)
  defp file_paths(%Movie{} = movie), do: Movie.file_paths(movie)
end
