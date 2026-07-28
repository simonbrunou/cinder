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

  # Pins the write path for issue #197's column, not just the ffprobe layer that produces it: the
  # hint is silent on nil, so a value silently dropped between probe and column looks identical to
  # "no default established" and would never fail a UI test.
  test "set_media_info persists the default audio language on a movie, nil when unestablished" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    {:ok, updated} =
      Catalog.set_media_info(movie, %{
        audio_languages: ["tur", "en"],
        default_audio_language: "tur",
        embedded_subtitles: [],
        sidecar_subtitles: []
      })

    assert updated.imported_default_audio_language == "tur"

    {:ok, cleared} =
      Catalog.set_media_info(updated, %{
        audio_languages: ["fre", "en"],
        embedded_subtitles: [],
        sidecar_subtitles: []
      })

    assert is_nil(cleared.imported_default_audio_language)
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
