defmodule Cinder.Catalog.MediaInfoTest do
  use Cinder.DataCase, async: true

  import Cinder.CatalogFixtures

  alias Cinder.Catalog

  test "set_media_info persists the three lists on a movie" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    {:ok, updated} =
      Catalog.set_media_info(movie, %{
        audio_languages: ["en", "fr"],
        embedded_subtitles: ["en"],
        sidecar_subtitles: ["fr"]
      })

    assert updated.imported_audio_languages == ["en", "fr"]
    assert updated.imported_embedded_subtitles == ["en"]
    assert updated.imported_sidecar_subtitles == ["fr"]
    assert Catalog.get_movie_by_id(updated.id).imported_sidecar_subtitles == ["fr"]
  end

  test "set_media_info persists on an episode" do
    series = series_fixture()
    season = season_fixture(series)
    ep = episode_fixture(season, %{file_path: "/tv/S (2020)/Season 01/S (2020) - S01E01.mkv"})

    {:ok, updated} =
      Catalog.set_media_info(ep, %{
        audio_languages: ["ja"],
        embedded_subtitles: ["en"],
        sidecar_subtitles: []
      })

    assert updated.imported_audio_languages == ["ja"]
    assert updated.imported_embedded_subtitles == ["en"]
    assert updated.imported_sidecar_subtitles == []
  end
end
