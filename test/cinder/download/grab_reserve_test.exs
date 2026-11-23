defmodule Cinder.Download.GrabReserveTest do
  @moduledoc """
  The grab disk guard's reserve (#1587): which in-flight rows count and how much
  (`Cinder.Download.GrabReserve.bytes/0`), each automatic grab path skipping a release once the
  reserve makes the difference, and each grab path recording the size the reserve reads.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase, only: [put_config: 2, put_env: 2]
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Acquisition.{AudiobookRelease, EbookRelease, Release}
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Movie, MovieLifecycle, UpgradeHunter}
  alias Cinder.Download
  alias Cinder.Download.{GrabReserve, Intent, Poller, TvPoller}
  alias Cinder.Repo

  @moduletag :capture_log

  @four_gb 4_000_000_000
  @nine_gib 9 * 1024 * 1024 * 1024

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      for poller <- [Poller, TvPoller, UpgradeHunter],
          do: :persistent_term.erase({poller, :last_run})
    end)

    put_env(:import_roots, ["/downloads"])
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub_clean_content()
  end

  defp disk_free!(bytes),
    do: put_env(:disk_stats_stub, {:ok, %{free_bytes: bytes, total_bytes: bytes * 10}})

  # Reports each `add` to the test process: a poller's `isolate/2` swallows a raise, so an
  # unstubbed mock cannot show that a path stayed away from the client.
  defp spy_on_add do
    test_pid = self()

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:added, release.title})
      {:ok, "remote-#{System.unique_integer([:positive])}"}
    end)
  end

  defp tv_grab!(attrs \\ []) do
    Repo.insert!(
      struct(
        %Grab{
          download_id: "grab-#{System.unique_integer([:positive])}",
          download_protocol: :torrent,
          release_size: @four_gb
        },
        attrs
      )
    )
  end

  defp book_grab!(attrs) do
    Repo.insert!(
      struct(
        %BookGrab{
          book_target_id: book_target(:ebook).id,
          download_id: "book-#{System.unique_integer([:positive])}",
          download_protocol: :torrent,
          release_size: @four_gb
        },
        attrs
      )
    )
  end

  defp intent!(status, remote_id, release \\ %{"title" => "T", "size" => @four_gb}, attrs \\ []) do
    Repo.insert!(
      struct(
        %Intent{
          operation_key: Ecto.UUID.generate(),
          kind: :movie,
          target_id: System.unique_integer([:positive]),
          protocol: :torrent,
          release: release,
          status: status,
          remote_id: remote_id
        },
        attrs
      )
    )
  end

  defp book_target(media_kind) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Books #{id}",
        kind: media_kind,
        handling: :standard,
        library_path: "/tmp/cinder-reserve-#{id}"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, media_kind, profile)
    target
  end

  defp tv_release(title, size \\ @four_gb),
    do: %{title: title, size: size, download_url: "magnet:?x=#{title}", seeders: 20}

  defp stub_tv_search(tvdb_id, releases) do
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn ^tvdb_id, "Show", 1 -> {:ok, releases} end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, releases} end)
  end

  describe "bytes/0" do
    test "nothing in flight reserves 0" do
      assert GrabReserve.bytes() == 0
    end

    test "a TV grab reserves what its progress leaves" do
      tv_grab!(download_progress: 0.5)
      assert GrabReserve.bytes() == 2_000_000_000
    end

    test "a TV grab with content_path set reserves 0" do
      tv_grab!(download_progress: 0.5, content_path: "/dl/done")
      assert GrabReserve.bytes() == 0
    end

    test "a downloading movie with nil progress reserves its whole size" do
      movie_fixture(status: :downloading, download_id: "m1", release_size: @four_gb)
      assert GrabReserve.bytes() == @four_gb
    end

    test "an upgrading movie with a download_id reserves by its progress" do
      movie_fixture(
        status: :upgrading,
        download_id: "m2",
        release_size: @four_gb,
        download_progress: 0.75
      )

      assert GrabReserve.bytes() == 1_000_000_000
    end

    test "an upgrading movie with no download_id reserves 0" do
      movie_fixture(status: :upgrading, release_size: @four_gb)
      assert GrabReserve.bytes() == 0
    end

    test "a movie in any other status reserves 0" do
      others = Ecto.Enum.values(Movie, :status) -- [:downloading, :upgrading]
      assert length(others) == 8

      for status <- others do
        movie_fixture(status: status, download_id: "other-#{status}", release_size: @four_gb)
      end

      assert GrabReserve.bytes() == 0
    end

    test "a book grab with nil content_path and nil progress reserves its whole size" do
      book_grab!([])
      assert GrabReserve.bytes() == @four_gb
    end

    test "a book grab reserves what its progress leaves" do
      book_grab!(download_progress: 0.25)
      assert GrabReserve.bytes() == 3_000_000_000
    end

    test "a book grab with content_path set reserves 0" do
      book_grab!(content_path: "/dl/book")
      assert GrabReserve.bytes() == 0
    end

    test "a submitted intent no owner row holds reserves its size" do
      intent!(:submitted, "i1")
      assert GrabReserve.bytes() == @four_gb
    end

    test "a reserved or cleanup-pending intent reserves 0" do
      intent!(:reserved, nil)
      intent!(:cleanup_pending, "i2")
      assert GrabReserve.bytes() == 0
    end

    test "a submitted intent with no usable size reserves 0" do
      intent!(:submitted, "no-size", %{"title" => "T"})
      intent!(:submitted, "text-size", %{"title" => "T", "size" => "4000000000"})
      intent!(:submitted, "zero-size", %{"title" => "T", "size" => 0})
      intent!(:submitted, "negative-size", %{"title" => "T", "size" => -5})
      assert GrabReserve.bytes() == 0
    end

    test "rows with no recorded size reserve 0" do
      tv_grab!(release_size: nil)
      book_grab!(release_size: nil)
      movie_fixture(status: :downloading, download_id: "m3")
      assert GrabReserve.bytes() == 0
    end

    test "a submitted intent and a downloading movie sharing its id count once" do
      intent!(:submitted, "shared")

      movie_fixture(
        status: :downloading,
        download_id: "shared",
        download_protocol: :torrent,
        release_size: @four_gb
      )

      assert GrabReserve.bytes() == @four_gb
    end

    test "a submitted intent whose TV grab holds its id counts once" do
      intent!(:submitted, "shared-tv")
      tv_grab!(download_id: "shared-tv")
      assert GrabReserve.bytes() == @four_gb
    end

    test "a submitted intent whose book grab holds its id counts once" do
      intent!(:submitted, "shared-book")
      book_grab!(download_id: "shared-book")
      assert GrabReserve.bytes() == @four_gb
    end

    # The owner's bytes are already in the `df` figure, so the intent must not add them back.
    test "a submitted intent whose owner finished downloading reserves 0" do
      intent!(:submitted, "done-tv")
      tv_grab!(download_id: "done-tv", content_path: "/dl/done")
      intent!(:submitted, "done-book")
      book_grab!(download_id: "done-book", content_path: "/dl/book")
      intent!(:submitted, "done-movie")

      movie_fixture(
        status: :available,
        download_id: "done-movie",
        download_protocol: :torrent,
        release_size: @four_gb
      )

      assert GrabReserve.bytes() == 0
    end

    test "an owner on the other protocol does not hide a submitted intent" do
      intent!(:submitted, "cross-tv")
      tv_grab!(download_id: "cross-tv", download_protocol: :usenet, content_path: "/dl/a")
      assert GrabReserve.bytes() == @four_gb
    end

    test "a book grab on the other protocol does not hide a submitted intent" do
      intent!(:submitted, "cross-book")
      book_grab!(download_id: "cross-book", download_protocol: :usenet, content_path: "/dl/b")
      assert GrabReserve.bytes() == @four_gb
    end

    test "a movie on the other protocol does not hide a submitted intent" do
      intent!(:submitted, "cross-movie")

      movie_fixture(
        status: :available,
        download_id: "cross-movie",
        download_protocol: :usenet
      )

      assert GrabReserve.bytes() == @four_gb
    end

    # `Download.client_for/1` reads a nil protocol as `:torrent`.
    test "a movie with a nil protocol holds a torrent intent's id, not a usenet one's" do
      movie_fixture(status: :available, download_id: "legacy")
      intent!(:submitted, "legacy")
      assert GrabReserve.bytes() == 0

      intent!(:submitted, "legacy", %{"title" => "U", "size" => @four_gb}, protocol: :usenet)
      assert GrabReserve.bytes() == @four_gb
    end

    # A client answers a duplicate add with the existing job's id (Transmission's
    # `torrent-duplicate`, qBittorrent's 409), so two rows can own one download.
    test "two movies on one download count it once" do
      for _copy <- 1..2 do
        movie_fixture(
          status: :downloading,
          download_id: "pack",
          download_protocol: :torrent,
          release_size: @four_gb
        )
      end

      assert GrabReserve.bytes() == @four_gb
    end

    test "rows of different kinds on one download count it once" do
      tv_grab!(download_id: "pack")
      book_grab!(download_id: "pack")

      movie_fixture(
        status: :downloading,
        download_id: "pack",
        download_protocol: :torrent,
        release_size: @four_gb
      )

      assert GrabReserve.bytes() == @four_gb
    end

    test "two rows on one download count the larger remainder, whichever comes first" do
      for {first, second} <- [{0.75, 0.25}, {0.25, 0.75}] do
        Repo.delete_all(Grab)
        Repo.delete_all(BookGrab)
        tv_grab!(download_id: "pack", download_progress: first)
        book_grab!(download_id: "pack", download_progress: second)
        assert GrabReserve.bytes() == 3_000_000_000
      end
    end

    test "two submitted intents on one download count it once" do
      intent!(:submitted, "pack")
      intent!(:submitted, "pack")
      assert GrabReserve.bytes() == @four_gb
    end

    test "one id on two protocols is two downloads" do
      tv_grab!(download_id: "same", download_protocol: :torrent)
      tv_grab!(download_id: "same", download_protocol: :usenet)
      assert GrabReserve.bytes() == 2 * @four_gb
    end

    test "a movie with a nil protocol shares a torrent row's download" do
      movie_fixture(status: :downloading, download_id: "legacy-pack", release_size: @four_gb)
      tv_grab!(download_id: "legacy-pack", download_protocol: :torrent)
      assert GrabReserve.bytes() == @four_gb
    end

    test "downloading movies with no download id stay separate" do
      for _copy <- 1..2, do: movie_fixture(status: :downloading, release_size: @four_gb)
      assert GrabReserve.bytes() == 2 * @four_gb
    end

    test "progress is clamped to 0..1" do
      tv_grab!(download_progress: 1.5)
      assert GrabReserve.bytes() == 0

      tv_grab!(download_progress: -0.5)
      assert GrabReserve.bytes() == @four_gb
    end

    test "a part byte rounds up" do
      tv_grab!(release_size: 3, download_progress: 0.5)
      assert GrabReserve.bytes() == 2
    end

    test "every in-flight kind adds up" do
      tv_grab!(download_progress: 0.5)
      book_grab!(release_size: 1_000)
      movie_fixture(status: :downloading, download_id: "sum-m", release_size: 500)
      intent!(:submitted, "sum-i", %{"title" => "T", "size" => 25})
      assert GrabReserve.bytes() == 2_000_000_000 + 1_000 + 500 + 25
    end
  end

  describe "the movie search" do
    test "one tick grabs only what the root can hold" do
      for {title, imdb} <- [
            {"Alpha", "tt0000001"},
            {"Bravo", "tt0000002"},
            {"Charlie", "tt0000003"}
          ] do
        {:ok, _movie} =
          Catalog.add_movie(%{
            tmdb_id: System.unique_integer([:positive]),
            title: title,
            imdb_id: imdb
          })
      end

      titles = %{"tt0000001" => "Alpha", "tt0000002" => "Bravo", "tt0000003" => "Charlie"}

      stub(Cinder.Acquisition.IndexerMock, :search, fn imdb ->
        {:ok,
         [
           %{
             title: "#{titles[imdb]}.2020.1080p.BluRay.x264-GRP",
             size: @four_gb,
             download_url: "magnet:?x=#{imdb}",
             seeders: 10
           }
         ]}
      end)

      spy_on_add()
      disk_free!(@nine_gib)
      start_supervised!({Poller, interval: 60_000})

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      movies = Repo.all(Movie)
      assert Enum.count(movies, &(&1.status == :downloading)) == 1

      held = Enum.reject(movies, &(&1.status == :downloading))
      assert length(held) == 2
      assert Enum.all?(held, &((&1.search_attempts || 0) == 0))
      assert Repo.aggregate(Intent, :count) == 0
      assert log =~ "insufficient free disk space"
    end

    test "skips a release only while an in-flight row's reserve makes the difference" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 7001, title: "Big", imdb_id: "tt7777001"})
      inflight = tv_grab!()

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt7777001" ->
        {:ok,
         [
           %{
             title: "Big.2020.1080p.BluRay.x264-GRP",
             size: @four_gb,
             download_url: "magnet:?x=big",
             seeders: 10
           }
         ]}
      end)

      spy_on_add()
      disk_free!(@nine_gib)
      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

      assert :ok = Poller.poll()
      refute_received {:added, _title}
      assert Repo.get!(Movie, movie.id).status in [:requested, :searching]

      Repo.delete!(inflight)
      assert :ok = Poller.poll()
      assert_received {:added, "Big.2020.1080p.BluRay.x264-GRP"}

      assert %Movie{status: :downloading, release_size: @four_gb} = Repo.get!(Movie, movie.id)
    end
  end

  describe "the TV sweep" do
    defp wanted_season(attrs \\ %{}) do
      series = series_fixture(Map.merge(%{tvdb_id: 99, monitor_strategy: :all}, attrs))
      season = season_fixture(series)
      {series, season}
    end

    test "one sweep grabs only what the root can hold" do
      {_series, season} = wanted_season()

      episodes =
        for number <- 1..3, do: episode_fixture(season, %{episode_number: number})

      stub_tv_search(
        99,
        for(number <- 1..3, do: tv_release("Show.S01E0#{number}.1080p.WEB.x264-GRP"))
      )

      spy_on_add()
      disk_free!(@nine_gib)
      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert [%Grab{release_size: @four_gb}] = Repo.all(Grab)

      reloaded = Enum.map(episodes, &Repo.get!(Episode, &1.id))
      held = Enum.filter(reloaded, &is_nil(&1.grab_id))
      assert length(held) == 2
      assert Enum.all?(held, &(&1.search_attempts == 0))
      assert log =~ "insufficient free disk space"
    end

    test "standard: skips a release only while an in-flight row's reserve makes the difference" do
      {_series, season} = wanted_season()
      episode = episode_fixture(season, %{episode_number: 1})
      inflight = movie_fixture(status: :downloading, download_id: "x", release_size: @four_gb)

      stub_tv_search(99, [tv_release("Show.S01E01.1080p.WEB.x264-GRP")])
      spy_on_add()
      disk_free!(@nine_gib)
      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

      assert :ok = TvPoller.poll()
      refute_received {:added, _title}
      assert %Episode{grab_id: nil, search_attempts: 0} = Repo.get!(Episode, episode.id)

      Repo.delete!(inflight)
      assert :ok = TvPoller.poll()
      assert_received {:added, "Show.S01E01.1080p.WEB.x264-GRP"}
      assert [%Grab{release_size: @four_gb}] = Repo.all(Grab)
    end

    test "anime: skips a release only while an in-flight row's reserve makes the difference" do
      put_config(:anime_preferences, preferred_groups: ["subsplease"], group_fallback_delay: 0)
      {_series, season} = wanted_season(%{media_profile: :anime})
      episode = episode_fixture(season, %{episode_number: 1})
      inflight = movie_fixture(status: :downloading, download_id: "x", release_size: @four_gb)

      stub_tv_search(99, [
        %{
          title: "[SubsPlease] Show S01E01 [1080p]",
          size: @four_gb,
          download_url: "anime-one"
        }
      ])

      spy_on_add()
      disk_free!(@nine_gib)
      start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

      assert :ok = TvPoller.poll()
      refute_received {:added, _title}
      assert %Episode{grab_id: nil, search_attempts: 0} = Repo.get!(Episode, episode.id)

      Repo.delete!(inflight)
      assert :ok = TvPoller.poll()
      assert_received {:added, "[SubsPlease] Show S01E01 [1080p]"}

      # An anime grab is written by `Catalog.create_grab_from_intent/1`.
      assert [%Grab{release_size: @four_gb, mapping_snapshot: %{}}] = Repo.all(Grab)
    end
  end

  describe "the upgrade hunter" do
    setup do
      put_env(UpgradeHunter, enabled: true)
      start_supervised!({UpgradeHunter, interval: 60_000})
      :ok
    end

    test "movie: skips a release only while an in-flight row's reserve makes the difference" do
      movie =
        movie_fixture(%{
          title: "Inception",
          imdb_id: "tt1375666",
          status: :available,
          file_path: "/lib/Inception/Inception.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000,
          imported_source: "WEBDL"
        })

      inflight = tv_grab!()

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
        {:ok, [tv_release("Inception.2010.1080p.BluRay.x264-GRP")]}
      end)

      spy_on_add()
      disk_free!(@nine_gib)

      assert :ok = UpgradeHunter.poll()
      refute_received {:added, _title}
      assert Repo.get!(Movie, movie.id).status == :available

      Repo.delete!(inflight)
      assert :ok = UpgradeHunter.poll()
      assert_received {:added, "Inception.2010.1080p.BluRay.x264-GRP"}

      assert %Movie{status: :upgrading, release_size: @four_gb} = Repo.get!(Movie, movie.id)
    end

    test "episode: skips a release only while an in-flight row's reserve makes the difference" do
      series = series_fixture(%{tvdb_id: 4242, title: "Show", monitor_strategy: :all})
      season = season_fixture(series)

      episode =
        episode_fixture(season, %{
          episode_number: 1,
          file_path: "/lib/Show/S01E01.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })

      inflight = movie_fixture(status: :downloading, download_id: "x", release_size: @four_gb)

      stub_tv_search(4242, [tv_release("Show.S01E01.1080p.BluRay-GRP")])
      spy_on_add()
      disk_free!(@nine_gib)

      assert :ok = UpgradeHunter.poll()
      refute_received {:added, _title}
      assert Repo.get!(Episode, episode.id).grab_id == nil

      Repo.delete!(inflight)
      assert :ok = UpgradeHunter.poll()
      assert_received {:added, "Show.S01E01.1080p.BluRay-GRP"}
      assert [%Grab{release_size: @four_gb}] = Repo.all(Grab)
    end
  end

  describe "recording the size" do
    defp movie_release(size \\ @four_gb) do
      %Release{title: "Pick", size: size, protocol: :torrent, download_url: "magnet:?x=pick"}
    end

    test "a manual movie grab records it" do
      movie = movie_fixture(status: :no_match)
      spy_on_add()

      assert {:ok, %Movie{release_size: @four_gb}} =
               Catalog.manual_grab_movie(movie, movie_release())
    end

    test "a manual movie upgrade records it" do
      movie = movie_fixture(status: :available, file_path: "/lib/M/M.mkv")
      spy_on_add()

      assert {:ok, %Movie{status: :upgrading, release_size: @four_gb}} =
               Catalog.manual_grab_movie(movie, movie_release())
    end

    test "a manual TV grab records it" do
      series = series_fixture(%{tvdb_id: 321, monitor_strategy: :all})
      season = season_fixture(series)
      episode_fixture(season, %{episode_number: 1})
      spy_on_add()

      release = %Release{
        title: "Show.S01E01",
        size: @four_gb,
        protocol: :torrent,
        season: 1,
        episodes: [1],
        download_url: "magnet:?x=tv"
      }

      assert {:ok, %Grab{release_size: @four_gb}} = Catalog.manual_grab_tv(series, 1, release)
    end

    test "an e-book grab records it" do
      target = book_target(:ebook)
      spy_on_add()

      release = %EbookRelease{
        title: "Le Guin - The Dispossessed (EPUB)",
        size: 1_500_000,
        download_url: "magnet:?xt=urn:btih:abc",
        protocol: :torrent,
        formats: [:epub]
      }

      assert {:ok, %BookGrab{release_size: 1_500_000}} =
               Download.grab_book_target(target, release)
    end

    test "an audiobook grab records it" do
      target = book_target(:audiobook)
      spy_on_add()

      release = %AudiobookRelease{
        title: "Le Guin - The Dispossessed (M4B)",
        size: 700_000_000,
        download_url: "magnet:?xt=urn:btih:def",
        protocol: :torrent,
        formats: [:m4b]
      }

      assert {:ok, %BookGrab{release_size: 700_000_000}} =
               Download.grab_book_target(target, release)
    end

    test "a release with no size records none" do
      movie = movie_fixture(status: :no_match)
      spy_on_add()

      assert {:ok, %Movie{release_size: nil}} =
               Catalog.manual_grab_movie(movie, movie_release(nil))
    end

    # A size of 0 would otherwise reach the owner row as a size the guard cannot use.
    test "a release with a zero size records none" do
      movie = movie_fixture(status: :no_match)
      spy_on_add()

      assert {:ok, %Movie{release_size: nil}} = Catalog.manual_grab_movie(movie, movie_release(0))
    end

    defp fail_first_add do
      calls = start_supervised!({Agent, fn -> 0 end})

      stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, :timeout}
          _retry -> {:ok, "retried-#{System.unique_integer([:positive])}"}
        end
      end)
    end

    defp clear_backoff, do: Repo.update_all(Intent, set: [next_attempt_at: nil])

    test "a movie intent the pending pass retries records it" do
      movie = movie_fixture(status: :no_match)
      fail_first_add()

      assert {:error, :timeout} = Catalog.manual_grab_movie(movie, movie_release())
      assert %Intent{status: :reserved} = Repo.one!(Intent)

      clear_backoff()
      assert :ok = Download.reconcile_pending_intents([:movie])

      assert %Movie{status: :downloading, release_size: @four_gb} = Repo.get!(Movie, movie.id)
    end

    test "a TV intent the pending pass retries records it" do
      series = series_fixture(%{tvdb_id: 322, monitor_strategy: :all})
      season = season_fixture(series)
      episode = episode_fixture(season, %{episode_number: 1})
      fail_first_add()

      release = %Release{
        title: "Show.S01E01",
        size: @four_gb,
        protocol: :torrent,
        download_url: "magnet:?x=tv-retry"
      }

      assert {:error, :timeout} = Download.grab_episodes(release, [episode.id])

      clear_backoff()
      assert :ok = Download.reconcile_pending_intents([:episode])
      assert [%Grab{release_size: @four_gb}] = Repo.all(Grab)
    end

    test "a book intent the pending pass retries records it" do
      target = book_target(:ebook)
      fail_first_add()

      release = %EbookRelease{
        title: "Le Guin - The Dispossessed (EPUB)",
        size: 1_500_000,
        download_url: "magnet:?xt=urn:btih:retry",
        protocol: :torrent,
        formats: [:epub]
      }

      assert {:error, :timeout} = Download.grab_book_target(target, release)

      clear_backoff()
      assert :ok = Download.reconcile_pending_intents([:book_target])
      assert [%BookGrab{release_size: 1_500_000}] = Repo.all(BookGrab)
    end

    test "a download with no size clears the size an earlier download left" do
      movie =
        movie_fixture(
          status: :available,
          file_path: "/lib/M/M.mkv",
          download_id: "old",
          release_size: @four_gb
        )

      spy_on_add()

      assert {:ok, %Movie{status: :upgrading, release_size: nil}} =
               Catalog.manual_grab_movie(movie, movie_release(nil))

      assert Repo.get!(Movie, movie.id).release_size == nil
    end

    # The caller's struct can predate the size the row holds: the write still clears it.
    test "attach clears the row's size through a struct that predates it" do
      stale = movie_fixture(status: :available, file_path: "/lib/M/M.mkv")

      stale
      |> Ecto.Changeset.change(release_size: @four_gb)
      |> Repo.update!()

      assert {:ok, %Movie{release_size: nil}} =
               MovieLifecycle.attach(stale, %{
                 download_id: "new",
                 download_protocol: :torrent,
                 release_title: "New"
               })

      assert Repo.get!(Movie, stale.id).release_size == nil
    end

    # Cancelling a `:downloading` movie keeps its `download_id` and `release_size`, so the status
    # ends the reserve.
    test "a cancelled movie stops reserving" do
      movie = movie_fixture(status: :downloading, download_id: "dl", release_size: @four_gb)
      stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
      assert GrabReserve.bytes() == @four_gb

      assert {:ok, %Movie{status: :cancelled, download_id: "dl", release_size: @four_gb}} =
               MovieLifecycle.cancel(movie, nil)

      assert GrabReserve.bytes() == 0
    end

    test "a re-queued movie drops its size" do
      movie = movie_fixture(status: :downloading, download_id: "dl", release_size: @four_gb)
      stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)

      assert {:ok, %Movie{status: :requested, release_size: nil}} =
               MovieLifecycle.record_failure(movie, :stalled)
    end
  end
end
