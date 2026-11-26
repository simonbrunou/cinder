defmodule Cinder.Download.SearchReportSweepTest do
  @moduledoc """
  What the sweeps do with an indexer source's report and errors
  (`Cinder.Acquisition.IndexerSource.Report`): an incomplete standard search runs no anime
  fallback and counts an attempt, a source's error reaches the movie poller as it is, and every
  seam call of one search goes to the source the search started with, even when the
  `:indexer_source` env changes during it.
  """
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Acquisition

  alias Cinder.Acquisition.{
    Audiobooks,
    BookScorer,
    Ebooks,
    IndexerMock,
    PassedIndexerMock,
    ReleaseJudge
  }

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.CallTrace
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Download
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase, only: [restore_env_on_exit: 1]

  # The pollers run in their own process, so the mocks must be global.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)
  end

  @until ~U[2030-01-01 00:00:00Z]

  defp failed_report,
    do: Report.put(Report.new(), {"native", 1}, "One", {:failed, :timeout})

  defp skipped_report,
    do: Report.put(Report.new(), {"native", 1}, "One", {:skipped, {:backoff, @until}})

  # Japanese animation under the default Auto profile: a standard search that finds nothing falls
  # back to the anime search.
  defp auto_anime_movie(imdb_id) do
    movie_fixture(%{
      title: "Your Name",
      year: 2016,
      imdb_id: imdb_id,
      original_language: "ja",
      genres: ["Animation"]
    })
  end

  defp auto_anime_series do
    series =
      series_fixture(%{
        tvdb_id: 99,
        monitor_strategy: :all,
        media_profile: :auto,
        original_language: "ja"
      })

    series |> Series.metadata_changeset(%{genres: ["Animation"]}) |> Repo.update!()
  end

  # Reports each anime query to the test, on `mock`: the id query as `{:id, imdb_id}`, each
  # free-text query as its text.
  defp spy_anime_queries(mock) do
    test_pid = self()

    stub(mock, :search, fn imdb_id ->
      send(test_pid, {:anime_query, mock, {:id, imdb_id}})
      {:ok, []}
    end)

    stub(mock, :search_movie_query, fn query, _opts ->
      send(test_pid, {:anime_query, mock, query})
      {:ok, []}
    end)

    stub(mock, :search_tv_query, fn query, _opts ->
      send(test_pid, {:anime_query, mock, query})
      {:ok, []}
    end)
  end

  describe "a standard movie search" do
    test "that an indexer failed runs no anime fallback and counts an attempt" do
      movie = auto_anime_movie("tt-incomplete")
      spy_anime_queries(IndexerMock)

      stub(IndexerMock, :search_movie, fn "tt-incomplete", _query, _opts ->
        {:ok, [], failed_report()}
      end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      refute_received {:anime_query, _mock, _query}
      assert %Movie{search_attempts: 1, status: :searching} = Repo.get!(Movie, movie.id)
    end

    test "that an indexer only skipped runs the anime fallback, as today" do
      movie = auto_anime_movie("tt-skipped")
      spy_anime_queries(IndexerMock)

      stub(IndexerMock, :search_movie, fn "tt-skipped", _query, _opts ->
        {:ok, [], skipped_report()}
      end)

      assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
      assert_received {:anime_query, IndexerMock, {:id, "tt-skipped"}}
      assert_received {:anime_query, IndexerMock, "Your Name 2016"}
    end

    test "returns the source's errors as they are" do
      movie = movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt-plain"})
      unanswered = {:no_indexer_answered, failed_report()}

      for reason <- [:no_indexers, {:indexers_backing_off, @until}, unanswered] do
        expect(IndexerMock, :search_movie, fn "tt-plain", _query, _opts -> {:error, reason} end)
        assert Download.start(Repo.get!(Movie, movie.id)) == {:error, reason}
      end
    end

    test "parks on no indexer answering and records no detail" do
      movie =
        movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt-park", search_attempts: 9})

      stub(IndexerMock, :search_movie, fn "tt-park", _query, _opts ->
        {:error, {:no_indexer_answered, failed_report()}}
      end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert %Movie{status: :search_failed, failure_reason: nil} = Repo.get!(Movie, movie.id)
    end

    test "sends its anime fallback to the source it started with" do
      restore_env_on_exit([:indexer_source])
      movie = auto_anime_movie("tt-switch")
      test_pid = self()

      spy_anime_queries(IndexerMock)
      spy_anime_queries(PassedIndexerMock)

      stub(IndexerMock, :search_movie, fn "tt-switch", _query, _opts ->
        send(test_pid, {:movie_search, IndexerMock})
        Application.put_env(:cinder, :indexer_source, PassedIndexerMock)
        {:ok, []}
      end)

      stub(PassedIndexerMock, :search_movie, fn _imdb_id, _query, _opts ->
        send(test_pid, {:movie_search, PassedIndexerMock})
        {:ok, []}
      end)

      assert {:ok, %Movie{status: :no_match}} = Download.start(movie)

      # The standard search, then the anime fallback's id and text queries.
      assert_received {:movie_search, IndexerMock}
      assert_received {:anime_query, IndexerMock, {:id, "tt-switch"}}
      assert_received {:anime_query, IndexerMock, "Your Name 2016"}
      refute_received {:movie_search, PassedIndexerMock}
      refute_received {:anime_query, PassedIndexerMock, _query}
    end
  end

  describe "a standard season search" do
    test "that an indexer failed runs no anime fallback and counts an attempt" do
      series = auto_anime_series()
      wanted = episode_fixture(season_fixture(series))
      stub(IndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, [], failed_report()} end)
      spy_anime_queries(IndexerMock)

      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
      assert :ok = TvPoller.poll()

      refute_received {:anime_query, _mock, _query}
      assert %Episode{grab_id: nil, search_attempts: 1} = Repo.get!(Episode, wanted.id)
    end

    test "that an indexer only skipped runs the anime fallback, as today" do
      series = auto_anime_series()
      episode_fixture(season_fixture(series))
      stub(IndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, [], skipped_report()} end)
      spy_anime_queries(IndexerMock)

      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
      assert :ok = TvPoller.poll()

      assert_received {:anime_query, IndexerMock, "Show"}
    end

    test "sends every season group and the anime fallback to the source it started with" do
      restore_env_on_exit([:indexer_source])
      series = auto_anime_series()
      episode_fixture(season_fixture(series, %{season_number: 1}))
      episode_fixture(season_fixture(series, %{season_number: 2}))
      test_pid = self()

      stub(IndexerMock, :search_tv, fn 99, "Show", season ->
        send(test_pid, {:season_search, IndexerMock, season})
        Application.put_env(:cinder, :indexer_source, PassedIndexerMock)
        {:ok, []}
      end)

      stub(PassedIndexerMock, :search_tv, fn 99, "Show", season ->
        send(test_pid, {:season_search, PassedIndexerMock, season})
        {:ok, []}
      end)

      spy_anime_queries(IndexerMock)
      spy_anime_queries(PassedIndexerMock)

      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
      assert :ok = TvPoller.poll()

      # Each season group, then the anime fallback's title query.
      assert_received {:season_search, IndexerMock, 1}
      assert_received {:season_search, IndexerMock, 2}
      assert_received {:anime_query, IndexerMock, "Show"}
      refute_received {:season_search, PassedIndexerMock, _season}
      refute_received {:anime_query, PassedIndexerMock, _query}
    end
  end

  describe "a book search" do
    @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}

    test "sends every later query to the source it started with" do
      for {search, structured, text} <- [
            {Ebooks, :search_ebook, :search_ebook_query},
            {Audiobooks, :search_audiobook, :search_audiobook_query}
          ] do
        restore_env_on_exit([:indexer_source])
        Application.put_env(:cinder, :indexer_source, IndexerMock)
        test_pid = self()

        expect(IndexerMock, structured, fn _author, _title, _opts ->
          Application.put_env(:cinder, :indexer_source, PassedIndexerMock)
          {:ok, []}
        end)

        expect(IndexerMock, text, fn _query, _opts ->
          send(test_pid, {:text_query, IndexerMock})
          {:ok, []}
        end)

        assert {:ok, [], true} = search.search(@work)
        assert_received {:text_query, IndexerMock}
      end
    end

    test "never passes the indexer_source opt to the scorer" do
      for {search, structured, text} <- [
            {Ebooks, :search_ebook, :search_ebook_query},
            {Audiobooks, :search_audiobook, :search_audiobook_query}
          ] do
        stub(PassedIndexerMock, structured, fn _author, _title, _opts -> {:ok, []} end)
        stub(PassedIndexerMock, text, fn _query, _opts -> {:ok, []} end)

        assert traced_opts({BookScorer, :evaluate_all}, fn ->
                 search.candidates(@work, language: "en", indexer_source: PassedIndexerMock)
               end) == [language: "en"]
      end
    end
  end

  describe "the pick entries" do
    defp anime_series_context do
      %{
        kind: :series,
        title: "Show",
        year: 2020,
        tvdb_id: 99,
        aliases: [],
        episodes: [%{id: 11, season_number: 1, episode_number: 1}],
        mappings: []
      }
    end

    setup do
      stub(PassedIndexerMock, :search_tv, fn _tvdb_id, _title, _season -> {:ok, []} end)
      stub(PassedIndexerMock, :search_tv_query, fn _query, _opts -> {:ok, []} end)
      :ok
    end

    @opts [max_size: 1, indexer_source: PassedIndexerMock]

    test "best_upgrade_releases/4 never passes the indexer_source opt to the judge" do
      assert traced_opts({ReleaseJudge, :judge}, fn ->
               Acquisition.best_upgrade_releases(
                 %Series{tvdb_id: 99, title: "Show"},
                 1,
                 [1],
                 @opts
               )
             end) == [max_size: 1]
    end

    test "best_anime_releases/3 never passes the indexer_source opt to the judge" do
      assert traced_opts({ReleaseJudge, :judge}, fn ->
               Acquisition.best_anime_releases(anime_series_context(), [11], @opts)
             end) == [max_size: 1]
    end

    test "best_anime_upgrades/4 never passes the indexer_source opt to the judge" do
      assert traced_opts({ReleaseJudge, :judge}, fn ->
               Acquisition.best_anime_upgrades(anime_series_context(), [11], & &1, @opts)
             end) == [max_size: 1]
    end
  end

  # The opts, the last argument, of the first call to the arity-3 function `{module, name}` while
  # `fun` runs.
  defp traced_opts({module, name}, fun) do
    {_result, [%{args: [_first, _second, opts]} | _calls]} =
      CallTrace.calls({module, name, 3}, fun)

    opts
  end
end
