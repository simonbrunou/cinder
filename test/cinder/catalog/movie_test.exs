defmodule Cinder.Catalog.MovieTest do
  use Cinder.DataCase, async: true

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  import Cinder.CatalogFixtures
  import Ecto.Changeset

  @anime_preferences %{
    audio_mode: :dual,
    subtitle_languages: [" JPN ", "ja", "FRA"],
    embedded_subtitle_mode: :require,
    preferred_release_groups: [" SubsPlease ", "subsplease"],
    blocked_release_groups: [" BadGroup "],
    group_fallback_delay: 21_600
  }

  test "anime_preferences_changeset/2 exclusively casts and normalizes Anime preferences" do
    changeset = Movie.anime_preferences_changeset(%Movie{}, @anime_preferences)

    assert changeset.valid?

    assert %Movie{
             audio_mode: :dual,
             subtitle_languages: ["ja", "fr"],
             embedded_subtitle_mode: :require,
             preferred_release_groups: ["subsplease"],
             blocked_release_groups: ["badgroup"],
             group_fallback_delay: 21_600
           } = apply_changes(changeset)

    general =
      Movie.changeset(
        %Movie{},
        Map.merge(@anime_preferences, %{tmdb_id: 1, title: "Ignored preferences"})
      )

    for field <- Map.keys(@anime_preferences), do: refute(get_change(general, field))
  end

  test "anime_preferences_changeset/2 rejects a negative fallback delay" do
    changeset = Movie.anime_preferences_changeset(%Movie{}, %{group_fallback_delay: -1})
    assert "must be greater than or equal to 0" in errors_on(changeset).group_fallback_delay
  end

  test "general and provider changesets preserve stored Anime preferences" do
    stored = struct(%Movie{tmdb_id: 1, title: "Stored"}, @anime_preferences)
    replacements = Map.new(@anime_preferences, fn {key, _value} -> {key, nil} end)

    for changeset <- [
          Movie.changeset(stored, Map.put(replacements, :title, "Admin")),
          Movie.metadata_changeset(stored, replacements),
          Movie.language_changeset(stored, Map.put(replacements, :preferred_language, "any"))
        ],
        field <- Map.keys(@anime_preferences) do
      assert Map.fetch!(apply_changes(changeset), field) == Map.fetch!(stored, field)
    end
  end

  test "a standard movie exposes no release policy snapshot by default" do
    assert %Movie{release_policy_snapshot: nil} = movie_fixture()
  end

  test "changeset/2 casts original_language and preferred_language" do
    cs =
      Movie.changeset(%Movie{}, %{
        tmdb_id: 1,
        title: "X",
        original_language: "fr",
        preferred_language: "french"
      })

    assert cs.valid?
    assert get_change(cs, :original_language) == "fr"
    assert get_change(cs, :preferred_language) == "french"
  end

  test "language_changeset/2 casts only preferred_language" do
    cs = Movie.language_changeset(%Movie{}, %{preferred_language: "any", status: :available})
    assert get_change(cs, :preferred_language) == "any"
    assert get_change(cs, :status) == nil
  end

  test "transition_changeset/2 casts imported_source" do
    cs = Movie.transition_changeset(%Movie{}, %{status: :available, imported_source: "bluray"})
    assert cs.changes.imported_source == "bluray"
  end

  describe "download metrics" do
    test "transition clears metrics when it leaves downloading" do
      movie = movie_fixture(%{status: :downloading})

      assert {:ok, movie} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })

      assert {:ok, updated} = Catalog.transition(movie, %{status: :downloaded})
      assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
    end

    test "a guarded transition clears metrics written after its snapshot" do
      movie = movie_fixture(%{status: :downloading})

      assert {:ok, _} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })

      assert {:ok, updated} =
               Catalog.transition(movie, %{status: :downloaded}, expect: :downloading)

      assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
    end

    test "changed movie metrics broadcast once and an equal snapshot is silent" do
      movie = movie_fixture(%{status: :downloading})
      Catalog.subscribe()
      metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

      assert {:ok, updated} = Catalog.update_movie_download_metrics(movie, metrics)
      assert_receive {:movie_updated, ^updated}
      assert {:ok, ^updated} = Catalog.update_movie_download_metrics(updated, metrics)
      refute_receive {:movie_updated, _}
    end

    test "a new downloading or upgrading run clears old metrics" do
      metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

      for {from, to} <- [{:downloading, :upgrading}, {:upgrading, :downloading}] do
        movie = movie_fixture(%{status: from})
        assert {:ok, movie} = Catalog.update_movie_download_metrics(movie, metrics)

        assert {:ok, updated} = Catalog.transition(movie, %{status: to})
        assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
      end
    end

    test "a stale movie metric write returns stale_status" do
      movie = movie_fixture(%{status: :downloading})
      assert {:ok, _} = Catalog.transition(movie, %{status: :cancelled})

      assert {:error, :stale_status} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 0.42,
                 download_speed: 1_500_000,
                 download_eta: 90
               })
    end
  end
end
