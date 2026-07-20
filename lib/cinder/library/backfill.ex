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
    info = %{
      sidecar_subtitles:
        record.file_path |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    }

    info =
      case probe(record.file_path) do
        {:ok, %{audio: a, subtitles: s}} ->
          Map.merge(info, %{audio_languages: a, embedded_subtitles: s})

        _ ->
          Map.merge(info, %{audio_languages: [], embedded_subtitles: []})
      end

    case Catalog.set_media_info(record, info) do
      {:ok, _} ->
        Subtitles.mark_release_sidecars(record.file_path, info.sidecar_subtitles)
        :ok

      {:error, e} ->
        Logger.warning("backfill failed for #{record.file_path}: #{inspect(e)}")
    end
  end

  defp probe(path) do
    case Application.get_env(:cinder, :media_info) do
      nil -> :error
      impl -> impl.probe(path)
    end
  end
end
