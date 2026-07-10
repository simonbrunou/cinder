defmodule Cinder.Catalog.MovieTest do
  use Cinder.DataCase, async: true

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  import Cinder.CatalogFixtures
  import Ecto.Changeset

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
