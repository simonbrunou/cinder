defmodule Mix.Tasks.Cinder.MediaInfo.BackfillTest do
  use Cinder.DataCase, async: false
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog.Episode
  alias Cinder.Library.Backfill

  setup :verify_on_exit!

  test "fills media info on an available movie from probe + sidecar scan" do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ ->
      {:ok, %{audio: ["eng"], subtitles: ["eng"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/lib/M (2020)/M (2020).fr.srt", 10}]}
    end)

    Backfill.run()

    m = Cinder.Catalog.get_movie_by_id(movie.id)
    assert m.imported_audio_languages == ["eng"]
    assert m.imported_embedded_subtitles == ["eng"]
    assert m.imported_sidecar_subtitles == ["fr"]
  end

  test "fills media info on an episode with a file_path" do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

    series = series_fixture()
    season = season_fixture(series)

    episode =
      episode_fixture(season, %{file_path: "/tv/S (2020)/Season 01/S (2020) - S01E01.mkv"})

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ ->
      {:ok, %{audio: ["ja"], subtitles: ["en"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/tv/S (2020)/Season 01/S (2020) - S01E01.fr.srt", 10}]}
    end)

    Backfill.run()

    e = Repo.get!(Episode, episode.id)
    assert e.imported_audio_languages == ["ja"]
    assert e.imported_embedded_subtitles == ["en"]
    assert e.imported_sidecar_subtitles == ["fr"]
  end
end
