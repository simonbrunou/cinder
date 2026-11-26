defmodule Cinder.Download.NativeSearchHoldTest do
  @moduledoc """
  The pollers' search hold and incomplete-search retry end to end through the real
  `Cinder.Acquisition.IndexerSource.Native` (#1655, #1624 point 3): each configured Newznab
  indexer behind its own host on the `Cinder.NewznabStub` plug (`Cinder.NewznabFixtures.route/1`),
  the lease's shortened test spacing, and the real movie and TV pollers. The stub tells the test
  process of every request, so a request the poller never sent shows as a message that never
  came; a raise would be swallowed by the poller's `isolate/2`. `Cinder.Download.SearchHoldTest`
  drives the same holds on `IndexerMock`.

  Native's clock is the real one unless a test moves it, since the poller's hold counts from
  `DateTime.utc_now/0`.
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Cinder.NewznabFixtures

  @moduletag :capture_log

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.ConfigCase
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Repo

  @backdated ~U[2020-01-01 00:00:00Z]

  setup do
    ConfigCase.put_env(:indexer_source, Native)

    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)
  end

  # Native's clock, `offset_s` seconds after the real one.
  defp shift_native_clock(offset_s),
    do: ConfigCase.put_env(Native, clock: fn -> DateTime.add(DateTime.utc_now(), offset_s) end)

  defp start_poller(poller, opts) do
    pid = start_supervised!({poller, Keyword.merge([interval: 60_000], opts)})
    # The poller's search processes reach the test's stub through the poller.
    :ok = Req.Test.allow(Cinder.NewznabStub, self(), pid)
    pid
  end

  # Backs `indexer` off for 1 min from now, as one failure answer does.
  defp back_off!(indexer) do
    :written = IndexerStatus.record(indexer, {:http_status, 500}, DateTime.utc_now())
    %{backoff_until: until} = IndexerStatus.read([indexer])[indexer.id]
    until
  end

  defp backdate!(schema, id) do
    schema |> Repo.get!(id) |> Ecto.Changeset.change(updated_at: @backdated) |> Repo.update!()
  end

  # Ends every hold the poller `pid` keeps, as the clock passing its end would.
  defp end_holds(pid) do
    :sys.replace_state(pid, fn state ->
      past = DateTime.add(DateTime.utc_now(), -1)
      holds = Process.get(:search_holds, %{})
      Process.put(:search_holds, Map.new(holds, fn {id, _until} -> {id, past} end))
      state
    end)
  end

  defp holds(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, :search_holds, %{})
  end

  # Every request the stub received so far, as `{host, t}`, caps fetches included.
  defp requests do
    receive do
      {:newznab_request, host, query} -> [{host, query["t"]} | requests()]
    after
      0 -> []
    end
  end

  defp empty_route, do: fn _conn, _query -> :default end

  describe "the incomplete-search retry through the movie poller" do
    setup do
      movie = movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093"})
      healthy = indexer!(:newznab, "ok.example")
      failing = indexer!(:newznab, "bad.example")

      route(%{
        "ok.example" => empty_route(),
        "bad.example" => fn _conn, query ->
          if query["t"] == "caps", do: :default, else: {500, "down"}
        end
      })

      %{movie: movie, healthy: healthy, failing: failing}
    end

    defp retry_after_s(movie, seconds) do
      at = DateTime.add(DateTime.utc_now(), -seconds) |> DateTime.truncate(:second)
      Movie |> Repo.get!(movie.id) |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()
    end

    test "strikes once, then 60 s later asks the failed indexer again", %{movie: movie} do
      start_poller(Poller, [])

      assert :ok = Poller.poll()
      assert {"ok.example", "movie"} in requests()
      assert %Movie{status: :searching, search_attempts: 1} = Repo.get!(Movie, movie.id)
      assert %{backoff: :failure} = IndexerStatus.read([indexer_by_host("bad.example")]) |> one()

      # 60 s later on both clocks: the poller's retry is due and the failed indexer's first
      # backoff step (1 min) has ended.
      retry_after_s(movie, 60)
      shift_native_clock(60)
      assert :ok = Poller.poll()

      assert {"bad.example", "movie"} in requests()
      assert %Movie{status: :searching, search_attempts: 2} = Repo.get!(Movie, movie.id)
    end

    test "59 s after the failure, the failed indexer is still skipped (control)", %{
      movie: movie
    } do
      start_poller(Poller, [])
      assert :ok = Poller.poll()
      _first = requests()

      retry_after_s(movie, 60)
      shift_native_clock(59)
      assert :ok = Poller.poll()

      second = requests()
      assert {"ok.example", "movie"} in second
      refute Enum.any?(second, &match?({"bad.example", _t}, &1))
    end
  end

  defp indexer_by_host(host) do
    Cinder.Indexers.searchable() |> Enum.find(&(&1.base_url == "https://#{host}"))
  end

  defp one(statuses), do: statuses |> Map.values() |> hd()

  describe "the backoff hold through the movie poller" do
    test "holds while every indexer backs off: no request, no strike, only the first tick writes" do
      # Already :searching, so the first tick has no status to advance.
      movie =
        movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093", status: :searching})

      first = indexer!(:newznab, "one.example")
      second = indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      until = Enum.min([back_off!(first), back_off!(second)], DateTime)
      pid = start_poller(Poller, search_retry_after: 0)

      # The tick that finds every indexer backing off writes the row's `updated_at` only:
      # `MovieLifecycle.start_search/2` writes it before every movie search, as on `IndexerMock`
      # (`SearchHoldTest`).
      backdate!(Movie, movie.id)
      assert :ok = Poller.poll()
      assert requests() == []
      assert Map.values(holds(pid)) == [until]

      assert %Movie{status: :searching, search_attempts: 0, updated_at: written} =
               Repo.get!(Movie, movie.id)

      assert written != @backdated

      # A second poll before `retry_at` sends nothing and writes nothing.
      backdate!(Movie, movie.id)
      assert :ok = Poller.poll()
      assert requests() == []

      assert %Movie{status: :searching, search_attempts: 0, updated_at: @backdated} =
               Repo.get!(Movie, movie.id)

      # Once the hold has ended and the backoff with it, the poller searches again.
      end_holds(pid)
      shift_native_clock(120)
      assert :ok = Poller.poll()

      assert {"one.example", "movie"} in requests()
    end

    test "searches through the one indexer out of backoff (positive control)" do
      movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093"})
      backing_off = indexer!(:newznab, "one.example")
      indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      back_off!(backing_off)
      start_poller(Poller, search_retry_after: 0)

      assert :ok = Poller.poll()

      sent = requests()
      assert {"two.example", "movie"} in sent
      refute Enum.any?(sent, &match?({"one.example", _t}, &1))
    end
  end

  defp tv_series(attrs),
    do: series_fixture(Map.merge(%{tvdb_id: 99, monitor_strategy: :all}, attrs))

  describe "the backoff hold through the standard TV sweep" do
    test "sends nothing, raises no attempt and writes nothing while every indexer backs off" do
      episode = episode_fixture(season_fixture(tv_series(%{})))
      first = indexer!(:newznab, "one.example")
      second = indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      until = Enum.min([back_off!(first), back_off!(second)], DateTime)
      backdate!(Episode, episode.id)
      pid = start_poller(TvPoller, search_retry_after: 0)

      assert :ok = TvPoller.poll()
      assert requests() == []
      assert holds(pid) == %{episode.id => until}

      assert :ok = TvPoller.poll()
      assert requests() == []

      assert %Episode{search_attempts: 0, updated_at: @backdated} =
               Repo.get!(Episode, episode.id)

      end_holds(pid)
      shift_native_clock(120)
      assert :ok = TvPoller.poll()

      assert {"one.example", "tvsearch"} in requests()
    end

    test "searches through the one indexer out of backoff (positive control)" do
      episode_fixture(season_fixture(tv_series(%{})))
      backing_off = indexer!(:newznab, "one.example")
      indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      back_off!(backing_off)
      start_poller(TvPoller, search_retry_after: 0)

      assert :ok = TvPoller.poll()

      sent = requests()
      assert {"two.example", "tvsearch"} in sent
      refute Enum.any?(sent, &match?({"one.example", _t}, &1))
    end
  end

  describe "the backoff hold through the anime sweep" do
    test "sends nothing, raises no attempt and writes nothing while every indexer backs off" do
      series = tv_series(%{media_profile: :anime})
      first_episode = episode_fixture(season_fixture(series))
      second_episode = episode_fixture(season_fixture(series, %{season_number: 2}))
      first = indexer!(:newznab, "one.example")
      second = indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      until = Enum.min([back_off!(first), back_off!(second)], DateTime)
      backdate!(Episode, first_episode.id)
      backdate!(Episode, second_episode.id)
      pid = start_poller(TvPoller, search_retry_after: 0)

      assert :ok = TvPoller.poll()
      assert requests() == []
      assert holds(pid) == %{first_episode.id => until, second_episode.id => until}

      assert :ok = TvPoller.poll()
      assert requests() == []

      for episode <- [first_episode, second_episode] do
        assert %Episode{search_attempts: 0, updated_at: @backdated} =
                 Repo.get!(Episode, episode.id)
      end

      end_holds(pid)
      shift_native_clock(120)
      assert :ok = TvPoller.poll()

      assert Enum.any?(requests(), &match?({"one.example", t} when t != "caps", &1))
    end

    test "searches through the one indexer out of backoff (positive control)" do
      series = tv_series(%{media_profile: :anime})
      episode_fixture(season_fixture(series))
      backing_off = indexer!(:newznab, "one.example")
      indexer!(:newznab, "two.example")
      route(%{"one.example" => empty_route(), "two.example" => empty_route()})
      back_off!(backing_off)
      start_poller(TvPoller, search_retry_after: 0)

      assert :ok = TvPoller.poll()

      sent = requests()
      assert Enum.any?(sent, &match?({"two.example", t} when t != "caps", &1))
      refute Enum.any?(sent, &match?({"one.example", _t}, &1))
    end
  end
end
