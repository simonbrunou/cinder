defmodule Cinder.Library.Backfill do
  @moduledoc """
  One-time media-info backfill for media imported before the feature landed, and for a row whose
  sidecars went unregistered because import adopted an already-present file (issue #128). Probes
  each `:available` movie / filed episode and scans for present sidecars, writing the three
  `imported_*` language lists and re-registering those sidecars in the subtitle manifest as
  Cinder-managed. Idempotent. Cannot recover sidecars that pre-feature imports left in the
  download folder (only the video was hardlinked then) — reports embedded tracks + whatever
  `.srt` currently sits next to the file.
  """
  require Logger
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Library.Sidecars
  alias Cinder.Repo
  alias Cinder.Subtitles

  def run do
    movies = Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
    episodes = Repo.all(from e in Episode, where: not is_nil(e.file_path))
    Enum.each(movies ++ episodes, &backfill_one/1)
  end

  defp backfill_one(record) do
    sidecars =
      Enum.map(file_paths(record), fn path ->
        {path, path |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
      end)

    info =
      Enum.reduce(file_paths(record), empty_info(sidecars), fn path, info ->
        case probe(path) do
          {:ok, %{audio: audio, subtitles: subtitles} = report} ->
            info
            |> Map.update!(:audio_languages, &Enum.uniq(&1 ++ audio))
            |> Map.update!(:embedded_subtitles, &Enum.uniq(&1 ++ subtitles))
            # First file wins: an Episode record spans several files, and only Movie (one file)
            # actually persists this. nil stays nil, so an unestablished default never warns.
            |> Map.update!(:default_audio_language, &(&1 || Map.get(report, :default_audio)))

          _ ->
            info
        end
      end)

    case Catalog.set_media_info(record, info) do
      {:ok, _} ->
        Enum.each(sidecars, fn {path, languages} ->
          Subtitles.mark_release_sidecars(path, languages)
        end)

        :ok

      {:error, e} ->
        Logger.warning("backfill failed for #{record.file_path}: #{inspect(e)}")
    end
  end

  defp file_paths(%Episode{} = episode), do: Episode.file_paths(episode)
  defp file_paths(%Movie{file_path: path}), do: [path]

  defp empty_info(sidecars) do
    %{
      audio_languages: [],
      embedded_subtitles: [],
      default_audio_language: nil,
      sidecar_subtitles: sidecars |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
    }
  end

  defp probe(path) do
    case Application.get_env(:cinder, :media_info) do
      nil -> :error
      impl -> impl.probe(path)
    end
  end
end
