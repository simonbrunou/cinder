defmodule Cinder.Download.AnimeMovieSearchTest do
  @moduledoc """
  `Download.start/1` for an Anime movie: what the household's Anime preferences and the title's
  Audio pick do to the search.

  Not async: Anime preferences are global application env with no per-title override, so a test
  that needs a non-default policy changes it for its duration.
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase
  import Mox

  alias Cinder.Catalog.Movie
  alias Cinder.Download

  setup :verify_on_exit!

  defp offer(imdb_id, release) do
    stub(Cinder.Acquisition.IndexerMock, :search, fn ^imdb_id -> {:ok, [release]} end)

    stub(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, categories: [5070] ->
      {:ok, [release]}
    end)
  end

  test "waits for a preferred group without a client add or a search attempt" do
    put_config(:anime_preferences, preferred_groups: ["subsplease"], group_fallback_delay: 3_600)

    movie =
      movie_fixture(%{
        title: "Inception",
        year: 2010,
        imdb_id: "tt-anime-wait",
        media_profile: :anime
      })

    offer("tt-anime-wait", %{
      title: "[Other] Inception 2010 [1080p]",
      size: 2_000_000_000,
      download_url: "anime-movie-wait",
      published_at: DateTime.utc_now(:second)
    })

    deny(Cinder.Download.ClientMock, :add, 2)

    assert {:ok, %Movie{status: :searching}} = Download.start(movie)
    assert %Movie{status: :searching, search_attempts: 0} = Repo.get!(Movie, movie.id)
  end

  test "freezes the title's Audio pick into the release-policy snapshot" do
    movie =
      movie_fixture(%{
        title: "Your Name",
        year: 2016,
        imdb_id: "tt-anime-audio-pick",
        original_language: "ja",
        preferred_language: "dual",
        media_profile: :anime
      })

    offer("tt-anime-audio-pick", %{
      title: "[Group] Your Name 2016 [1080p]",
      size: 2_000_000_000,
      download_url: "magnet:?audio-pick"
    })

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-audio-pick"} end)

    assert {:ok, %Movie{status: :downloading}} = Download.start(movie)

    # Dual is the original language plus French, read when the snapshot freezes, not only when a
    # view displays the pick.
    assert %Movie{release_policy_snapshot: %{"required_audio_languages" => ["ja", "fr"]}} =
             Repo.get!(Movie, movie.id)
  end
end
