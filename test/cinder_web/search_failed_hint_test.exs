defmodule CinderWeb.SearchFailedHintTest do
  # The hint for a movie at `:search_failed` reads the status only, and nothing on the row says
  # which path parked it (#1721). Each test parks a movie through one lifecycle path and reads the
  # hint off the reloaded row, so the hint must hold for a download-client refusal as for a failed
  # indexer search.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import CinderWeb.LiveHelpers, only: [pipeline_hint: 1]

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Catalog.{Movie, MovieLifecycle}
  alias Cinder.Download

  @hint "Cinder couldn't search the indexers or hand a release to the download client. " <>
          "Open it to retry."

  # More calls than the search budget allows, so a loop that never parks ends and fails.
  @max_strikes 20

  test "a movie parked on a permanent download-client submission error shows the hint" do
    for reason <- Download.permanent_submission_errors() do
      movie = movie_fixture(%{status: :searching})

      assert {:ok, %Movie{status: :search_failed}} = MovieLifecycle.record_failure(movie, reason)
      assert {reason, pipeline_hint(Repo.reload!(movie))} == {reason, @hint}
    end
  end

  test "a movie parked when download-client submission failures spend the search budget shows the hint" do
    movie = movie_fixture(%{status: :requested})

    strikes =
      Enum.reduce_while(1..@max_strikes, 0, fn n, _ ->
        :ok = MovieLifecycle.record_submission_failure(movie.id, :no_client, fn -> :ok end)

        case Repo.reload!(movie) do
          %Movie{status: :search_failed} -> {:halt, n}
          %Movie{} -> {:cont, n}
        end
      end)

    parked = Repo.reload!(movie)
    assert %Movie{status: :search_failed} = parked
    assert strikes > 1
    assert pipeline_hint(parked) == @hint
  end

  test "a movie parked when failed indexer searches spend the search budget shows the hint" do
    movie = movie_fixture(%{status: :requested})
    reason = {:no_indexer_answered, %Report{failed_calls: 1}}

    # The verb compares the row with the movie it is given, so each call takes the last answer.
    {strikes, _last} =
      Enum.reduce_while(1..@max_strikes, {0, movie}, fn n, {_, current} ->
        case MovieLifecycle.record_failure(current, reason) do
          {:ok, %Movie{status: :search_failed} = parked} -> {:halt, {n, parked}}
          {:ok, %Movie{} = counted} -> {:cont, {n, counted}}
        end
      end)

    parked = Repo.reload!(movie)
    assert %Movie{status: :search_failed} = parked
    assert strikes > 1
    assert pipeline_hint(parked) == @hint
  end
end
