defmodule Cinder.Download.SearchHoldTest do
  @moduledoc """
  The search hold of the movie and TV pollers (`Cinder.Download.PollerSkeleton`): a search that
  reached no indexer, because every indexer that could take a query was skipped
  (`{:indexers_backing_off, retry_at}`) or none is enabled (`:no_indexers`), costs no strike and
  no attempt, and the poller searches that title again only once `retry_at` passes, or
  `no_indexers_hold` seconds after the search.

  Every test runs the pollers with `search_retry_after: 0`, so the search backoff never stops a
  second search: only the hold can. A test counts searches through stubs that send each one to
  the test process, since the poller's `isolate/2` swallows a raise from a stub.
  """
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Acquisition.IndexerMock
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  # The pollers run in their own process, so the mocks must be global.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)
  end

  @backdated ~U[2020-01-01 00:00:00Z]

  defp in_an_hour, do: DateTime.add(DateTime.utc_now(), 3_600)
  defp backoff, do: {:indexers_backing_off, in_an_hour()}

  defp failed_report,
    do: Report.put(Report.new(), {"native", 1}, "One", {:failed, :timeout})

  defp start_poller(poller, opts \\ []) do
    start_supervised!({poller, Keyword.merge([interval: 60_000, search_retry_after: 0], opts)})
  end

  # The holds the poller `pid` keeps in its process dictionary, by unit id.
  defp holds(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, :search_holds, %{})
  end

  defp backdate!(schema, id) do
    schema |> Repo.get!(id) |> Ecto.Changeset.change(updated_at: @backdated) |> Repo.update!()
  end

  defp plain_movie(imdb_id),
    do: movie_fixture(%{title: "Plain", year: 2020, imdb_id: imdb_id})

  # Answers every id search for `imdb_id` with `answer` and reports it to the test.
  defp answer_movie_search(imdb_id, answer) do
    test_pid = self()

    stub(IndexerMock, :search, fn ^imdb_id ->
      send(test_pid, {:movie_search, imdb_id})
      answer
    end)
  end

  defp searches(tag) do
    receive do
      {^tag, _detail} -> 1 + searches(tag)
    after
      0 -> 0
    end
  end

  defp movie_state(movie) do
    %Movie{status: status, search_attempts: attempts} = Repo.get!(Movie, movie.id)
    {status, attempts}
  end

  describe "the movie poller" do
    test "holds a movie every indexer backs off for, with no strike and no write on the held tick" do
      movie = plain_movie("tt-backoff")
      answer_movie_search("tt-backoff", {:error, backoff()})
      start_poller(Poller)

      assert :ok = Poller.poll()
      assert_received {:movie_search, "tt-backoff"}
      assert movie_state(movie) == {:searching, 0}

      backdate!(Movie, movie.id)
      assert :ok = Poller.poll()

      refute_received {:movie_search, "tt-backoff"}

      assert %Movie{status: :searching, search_attempts: 0, updated_at: @backdated} =
               Repo.get!(Movie, movie.id)
    end

    test "holds a movie until the backoff's own end" do
      plain_movie("tt-until")
      retry_at = in_an_hour()
      answer_movie_search("tt-until", {:error, {:indexers_backing_off, retry_at}})
      pid = start_poller(Poller)

      assert :ok = Poller.poll()

      assert Map.values(holds(pid)) == [retry_at]
    end

    test "searches again on the next tick after a backoff that already ended, with no strike" do
      movie = plain_movie("tt-past")
      past = DateTime.add(DateTime.utc_now(), -1)
      answer_movie_search("tt-past", {:error, {:indexers_backing_off, past}})
      start_poller(Poller)

      assert :ok = Poller.poll()
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 2
      assert movie_state(movie) == {:searching, 0}
    end

    test "searches again once the hold ends, and holds again with no strike" do
      movie = plain_movie("tt-ends")
      answer_movie_search("tt-ends", {:error, backoff()})
      pid = start_poller(Poller)

      assert :ok = Poller.poll()
      end_holds(pid)
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 2
      assert movie_state(movie) == {:searching, 0}
      assert [movie.id] == Map.keys(holds(pid))
      assert [until] = Map.values(holds(pid))
      assert DateTime.compare(until, DateTime.utc_now()) == :gt
    end

    test "holds a movie with no enabled indexer for 60 s after the search, with no strike" do
      movie = plain_movie("tt-none")
      answer_movie_search("tt-none", {:error, :no_indexers})
      pid = start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

      before = DateTime.utc_now()
      assert :ok = Poller.poll()
      later = DateTime.utc_now()

      [until] = Map.values(holds(pid))
      assert DateTime.compare(until, DateTime.add(before, 60)) != :lt
      assert DateTime.compare(until, DateTime.add(later, 60)) != :gt

      backdate!(Movie, movie.id)
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 1

      assert %Movie{status: :searching, search_attempts: 0, updated_at: @backdated} =
               Repo.get!(Movie, movie.id)
    end

    test "with no_indexers_hold: 0, searches a movie with no enabled indexer again on the next tick" do
      movie = plain_movie("tt-none-zero")
      answer_movie_search("tt-none-zero", {:error, :no_indexers})
      pid = start_poller(Poller, no_indexers_hold: 0)

      assert :ok = Poller.poll()
      assert holds(pid) == %{}
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 2
      assert movie_state(movie) == {:searching, 0}
    end

    test "holds an anime movie every indexer backs off for, with no strike" do
      movie =
        movie_fixture(%{
          title: "Your Name",
          year: 2016,
          imdb_id: "tt-anime-hold",
          media_profile: :anime
        })

      test_pid = self()
      until = in_an_hour()

      stub(IndexerMock, :search, fn "tt-anime-hold" ->
        send(test_pid, {:anime_search, :id})
        {:error, {:indexers_backing_off, until}}
      end)

      stub(IndexerMock, :search_movie_query, fn _query, _opts ->
        send(test_pid, {:anime_search, :query})
        {:error, {:indexers_backing_off, until}}
      end)

      start_poller(Poller)
      assert :ok = Poller.poll()
      first = searches(:anime_search)
      assert first > 0

      assert :ok = Poller.poll()

      assert searches(:anime_search) == 0
      assert movie_state(movie) == {:searching, 0}
    end

    test "strikes when one anime query fails and another backs off, as today" do
      movie =
        movie_fixture(%{
          title: "Your Name",
          year: 2016,
          imdb_id: "tt-anime-mixed",
          media_profile: :anime
        })

      stub(IndexerMock, :search, fn "tt-anime-mixed" -> {:error, :timeout} end)

      stub(IndexerMock, :search_movie_query, fn _query, _opts ->
        {:error, backoff()}
      end)

      pid = start_poller(Poller)
      assert :ok = Poller.poll()

      assert movie_state(movie) == {:searching, 1}
      assert holds(pid) == %{}
    end

    test "strikes on no indexer answering and on a transport error, as today" do
      for {imdb_id, reason} <- [
            {"tt-unanswered", {:no_indexer_answered, failed_report()}},
            {"tt-timeout", :timeout}
          ] do
        movie = plain_movie(imdb_id)
        answer_movie_search(imdb_id, {:error, reason})
        pid = start_poller(Poller)

        assert :ok = Poller.poll()
        assert :ok = Poller.poll()

        assert {imdb_id, searches(:movie_search), movie_state(movie)} ==
                 {imdb_id, 2, {:searching, 2}}

        assert holds(pid) == %{}
        stop_supervised!(Poller)
      end
    end

    test "forgets a hold when the movie leaves the search pass" do
      movie = plain_movie("tt-leaves")
      answer_movie_search("tt-leaves", {:error, backoff()})
      pid = start_poller(Poller)

      assert :ok = Poller.poll()
      set_status!(movie, :search_failed)
      assert :ok = Poller.poll()
      assert holds(pid) == %{}

      set_status!(movie, :searching)
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 2
    end

    test "a restart forgets every hold: one more search, still with no strike" do
      movie = plain_movie("tt-restart")
      answer_movie_search("tt-restart", {:error, backoff()})
      start_poller(Poller)

      assert :ok = Poller.poll()
      stop_supervised!(Poller)
      start_poller(Poller)
      assert :ok = Poller.poll()

      assert searches(:movie_search) == 2
      assert movie_state(movie) == {:searching, 0}
    end
  end

  defp set_status!(movie, status) do
    Movie |> Repo.get!(movie.id) |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  # Ends every hold the poller `pid` keeps, as the clock passing its end would: the function
  # `:sys.replace_state/2` takes runs in the poller's process.
  defp end_holds(pid) do
    :sys.replace_state(pid, fn state ->
      past = DateTime.add(DateTime.utc_now(), -1)
      holds = Process.get(:search_holds, %{})
      Process.put(:search_holds, Map.new(holds, fn {id, _until} -> {id, past} end))
      state
    end)
  end

  defp tv_series(attrs \\ %{}),
    do: series_fixture(Map.merge(%{tvdb_id: 99, monitor_strategy: :all}, attrs))

  # Answers each season query of series 99 with `by_season[season]` and reports it to the test.
  defp answer_season_search(by_season) do
    test_pid = self()

    stub(IndexerMock, :search_tv, fn 99, "Show", season ->
      send(test_pid, {:season_search, season})
      Map.fetch!(by_season, season)
    end)
  end

  defp season_searches(season) do
    receive do
      {:season_search, ^season} -> 1 + season_searches(season)
    after
      0 -> 0
    end
  end

  describe "the TV poller" do
    test "holds a backing-off season group, and searches, grabs and bumps the others as before" do
      series = tv_series()
      held = episode_fixture(season_fixture(series, %{season_number: 1}))
      grabbed = episode_fixture(season_fixture(series, %{season_number: 2}))
      missed = episode_fixture(season_fixture(series, %{season_number: 3}))

      release = %{
        title: "Show.S02E01.1080p.WEB.x264-GRP",
        size: 2_000_000_000,
        download_url: "season-two"
      }

      answer_season_search(%{1 => {:error, backoff()}, 2 => {:ok, [release]}, 3 => {:ok, []}})
      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "grab-season-two"} end)

      stub(Cinder.Download.ClientMock, :status, fn "grab-season-two" ->
        {:ok, %{state: :downloading, progress: 0.0}}
      end)

      start_poller(TvPoller)
      assert :ok = TvPoller.poll()

      assert Repo.get!(Episode, grabbed.id).grab_id
      assert %Episode{search_attempts: 0} = Repo.get!(Episode, held.id)
      assert %Episode{search_attempts: 1} = Repo.get!(Episode, missed.id)

      backdate!(Episode, held.id)
      assert :ok = TvPoller.poll()

      assert {season_searches(1), season_searches(3)} == {1, 2}

      assert %Episode{grab_id: nil, search_attempts: 0, updated_at: @backdated} =
               Repo.get!(Episode, held.id)
    end

    test "holds an episode with no enabled indexer for 60 s after the search, with no attempt" do
      series = tv_series()
      episode = episode_fixture(season_fixture(series))
      answer_season_search(%{1 => {:error, :no_indexers}})
      pid = start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

      before = DateTime.utc_now()
      assert :ok = TvPoller.poll()
      later = DateTime.utc_now()

      assert [{id, until}] = Map.to_list(holds(pid))
      assert id == episode.id
      assert DateTime.compare(until, DateTime.add(before, 60)) != :lt
      assert DateTime.compare(until, DateTime.add(later, 60)) != :gt

      assert :ok = TvPoller.poll()

      assert season_searches(1) == 1
      assert %Episode{search_attempts: 0} = Repo.get!(Episode, episode.id)
    end

    test "with no_indexers_hold: 0, searches an episode with no enabled indexer again on the next tick" do
      series = tv_series()
      episode = episode_fixture(season_fixture(series))
      answer_season_search(%{1 => {:error, :no_indexers}})
      start_poller(TvPoller, no_indexers_hold: 0)

      assert :ok = TvPoller.poll()
      assert :ok = TvPoller.poll()

      assert season_searches(1) == 2
      assert %Episode{search_attempts: 0} = Repo.get!(Episode, episode.id)
    end

    test "counts an attempt when no indexer answered, as today" do
      series = tv_series()
      episode = episode_fixture(season_fixture(series))
      answer_season_search(%{1 => {:error, {:no_indexer_answered, failed_report()}}})
      pid = start_poller(TvPoller)

      assert :ok = TvPoller.poll()
      assert :ok = TvPoller.poll()

      assert season_searches(1) == 2
      assert %Episode{search_attempts: 2} = Repo.get!(Episode, episode.id)
      assert holds(pid) == %{}
    end

    test "runs no anime fallback for an Auto series while one of its season groups is held" do
      series = tv_series(%{media_profile: :auto, original_language: "ja"})
      series |> Series.metadata_changeset(%{genres: ["Animation"]}) |> Repo.update!()
      held = episode_fixture(season_fixture(series))
      other = episode_fixture(season_fixture(series, %{season_number: 2}))
      answer_season_search(%{1 => {:error, backoff()}, 2 => {:ok, []}})
      test_pid = self()

      stub(IndexerMock, :search_tv_query, fn query, _opts ->
        send(test_pid, {:anime_query, query})
        {:ok, []}
      end)

      pid = start_poller(TvPoller)
      assert :ok = TvPoller.poll()
      # The second tick visits the series with season 2 alone, season 1 held.
      assert :ok = TvPoller.poll()

      assert {season_searches(1), season_searches(2)} == {1, 2}
      refute_received {:anime_query, _query}
      assert %Episode{search_attempts: 0} = Repo.get!(Episode, held.id)
      assert %Episode{search_attempts: 2} = Repo.get!(Episode, other.id)

      # Once the hold ends, the series visit runs the fallback again (positive control).
      end_holds(pid)
      answer_season_search(%{1 => {:ok, []}, 2 => {:ok, []}})
      assert :ok = TvPoller.poll()

      assert_received {:anime_query, "Show"}
    end

    test "holds every episode of an anime search every indexer backs off for, with no attempt" do
      series = tv_series(%{media_profile: :anime})
      first = episode_fixture(season_fixture(series))
      second = episode_fixture(season_fixture(series, %{season_number: 2}))
      test_pid = self()

      stub(IndexerMock, :search_tv, fn 99, "Show", _season ->
        send(test_pid, {:anime_search, :id})
        {:error, backoff()}
      end)

      stub(IndexerMock, :search_tv_query, fn _query, _opts ->
        send(test_pid, {:anime_search, :query})
        {:error, backoff()}
      end)

      pid = start_poller(TvPoller)
      assert :ok = TvPoller.poll()
      assert searches(:anime_search) > 0
      assert holds(pid) |> Map.keys() |> Enum.sort() == Enum.sort([first.id, second.id])

      backdate!(Episode, first.id)
      assert :ok = TvPoller.poll()

      assert searches(:anime_search) == 0

      assert %Episode{search_attempts: 0, updated_at: @backdated} = Repo.get!(Episode, first.id)
      assert %Episode{search_attempts: 0} = Repo.get!(Episode, second.id)
    end
  end
end
