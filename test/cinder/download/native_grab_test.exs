defmodule Cinder.Download.NativeGrabTest do
  @moduledoc """
  A movie grab end to end through the real `Cinder.Acquisition.IndexerSource.Native`, the real
  movie poller and `Cinder.Download`, and the real SABnzbd client (#1659, #1624 point 3). The
  configured Newznab indexer answers its search on the `Cinder.NewznabStub` plug
  (`Cinder.NewznabFixtures.route/1`). SABnzbd fetches the release's link through its
  `fetch_plug`, `Cinder.SabnzbdStub`, which also answers its API: a request on the indexer's
  host is the link, one on `localhost` the API. Every stub tells the test process of each
  request, so a request the poller never sent shows as a message that never came.

  Native is the selected source, so a failed fetch through it is not a source switch in flight
  (`Cinder.Download.GrabFailure.guard_fetch/2`).
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Cinder.NewznabFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  @moduletag :capture_log

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Catalog.Movie
  alias Cinder.ConfigCase
  alias Cinder.Download.Client.Sabnzbd
  alias Cinder.Download.{Intent, Poller}
  alias Cinder.NzbFixture
  alias Cinder.Repo

  @base "http://192.168.1.10:5076"
  @host "192.168.1.10"

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    ConfigCase.put_env(:indexer_source, Native)
    ConfigCase.put_env(:download_clients, %{usenet: Sabnzbd})
    stub_clean_content()
    on_exit(fn -> :persistent_term.erase({Poller, :last_run}) end)
  end

  defp start_poller, do: start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

  # Searches answer one 1080p release of the movie whose link sits on the base URL.
  defp search_answers(title) do
    rss =
      rss([
        item(
          "#{title}.2020.1080p.WEB-DL.x264-GRP",
          {:nzb, "#{@base}/getnzb/1.nzb?apikey=#{key()}"},
          size: 4_000_000_000,
          category: 2040
        )
      ])

    route(%{
      @host => fn
        _conn, %{"t" => "caps"} -> :default
        _conn, _query -> rss
      end
    })
  end

  # SABnzbd's stub: `link` answers the release's link, and its API accepts every added file.
  defp sabnzbd(link) do
    test_pid = self()

    Req.Test.stub(Cinder.SabnzbdStub, fn conn ->
      case {conn.host, conn.params["mode"]} do
        {@host, _mode} ->
          send(test_pid, {:link_request, conn.request_path})
          respond(conn, link.(conn))

        {_api, "addfile"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:added, body})
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-1"]})

        {_api, mode} when mode in ["queue", "history"] ->
          Req.Test.json(conn, %{mode => %{"slots" => []}})
      end
    end)
  end

  defp searches_sent do
    receive do
      {:newznab_request, _host, %{"t" => t}} when t != "caps" -> [t | searches_sent()]
      {:newznab_request, _host, _caps} -> searches_sent()
    after
      0 -> []
    end
  end

  defp holds(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, :search_holds, %{})
  end

  test "a grab of a Native Newznab result on a LAN base URL reaches SABnzbd with the NZB bytes" do
    movie = movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093"})
    indexer!(:newznab, "unused.example", %{base_url: @base})
    search_answers("Plain")
    nzb = NzbFixture.minimal()
    sabnzbd(fn _conn -> nzb end)
    start_poller()

    assert :ok = Poller.poll()

    assert_received {:link_request, "/getnzb/1.nzb"}
    assert_received {:added, body}
    assert body =~ nzb
    assert %Movie{download_id: "nzo-1"} = Repo.get!(Movie, movie.id)
  end

  test "a grab answered with HTTP 429 and Retry-After: 600 limits the indexer, holds the movie's intent and holds a search of another movie" do
    movie = movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093"})
    indexer = indexer!(:newznab, "unused.example", %{base_url: @base})
    search_answers("Plain")
    sabnzbd(fn _conn -> {429, [{"retry-after", "600"}], ""} end)
    pid = start_poller()
    now = DateTime.utc_now(:second)

    assert :ok = Poller.poll()

    assert_received {:link_request, "/getnzb/1.nzb"}
    refute_received {:added, _body}
    assert %{backoff: :limit, backoff_until: until} = IndexerStatus.read([indexer])[indexer.id]
    assert DateTime.diff(until, now) in 600..601
    assert %Movie{search_attempts: attempts} = Repo.get!(Movie, movie.id)
    assert [%Intent{attempt_count: 0, next_attempt_at: ^until}] = Repo.all(Intent)
    _first_tick = searches_sent()

    # The next ticks read the intent's backoff: no search, no fetch, no new attempt.
    for _tick <- 1..2 do
      assert :ok = Poller.poll()
      assert searches_sent() == []
      refute_received {:link_request, _path}
      assert %Movie{search_attempts: ^attempts} = Repo.get!(Movie, movie.id)
    end

    # A second movie, with no intent, holds while its only indexer is limited.
    other = movie_fixture(%{title: "Other", year: 2021, imdb_id: "tt0234215"})
    assert :ok = Poller.poll()

    assert searches_sent() == []
    assert Map.get(holds(pid), other.id) == until
    assert %Movie{search_attempts: 0} = Repo.get!(Movie, other.id)
  end
end
