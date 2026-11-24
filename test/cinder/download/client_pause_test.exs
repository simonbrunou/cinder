defmodule Cinder.Download.ClientPauseTest do
  @moduledoc """
  A paused download client (#1598), through `Cinder.Download.Watch` and each kind's real metrics
  writer: a movie, a TV grab and a book grab each keep their pause on the row, and the time spent
  paused does not count toward the stall reaper's 24 h cap.

  `async: false` because the reaper is switched on through application env.
  """
  use Cinder.DataCase, async: false

  @moduletag :capture_log

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookBlockedRelease, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Grab, Movie, MovieLifecycle}
  alias Cinder.Download.{BookPoller, Poller, StallReaper, TvPoller, Watch}
  alias Cinder.Download.Client.{Nzbget, QBittorrent, Transmission}

  @client Cinder.Download.SabnzbdClientMock
  @kinds [:movie, :grab, :book]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    put_config(StallReaper, enabled: true)
    stub(@client, :files, fn _id -> {:ok, []} end)
    :ok
  end

  defp row(:movie) do
    movie_fixture(%{
      status: :downloading,
      download_id: "job-movie",
      download_protocol: :usenet,
      release_title: "Paused.Movie.2026.1080p"
    })
  end

  defp row(:grab) do
    episode = series_fixture() |> season_fixture() |> episode_fixture()

    {:ok, grab} =
      Catalog.create_grab("job-grab", :usenet, [episode.id], "Paused.Show.S01E01.1080p")

    grab
  end

  defp row(:book) do
    id = System.unique_integer([:positive])

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Paused Book #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL#{id}W"}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, "job-book", :usenet, "Paused.Book.#{id}")
    grab
  end

  defp writer(%Movie{}), do: &MovieLifecycle.track/2
  defp writer(%Grab{}), do: &Catalog.update_grab_download_metrics/2
  defp writer(%BookGrab{}), do: &Books.Grabs.track/2

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(:second), -hours, :hour)

  # Puts a row in a known clock state with a raw write, then reads it back as a poller would.
  defp seed(%schema{id: id} = row, attrs) do
    {1, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: Map.to_list(attrs))
    Repo.reload!(row)
  end

  defp tick(row, report) do
    expect(@client, :status, fn id ->
      assert id == row.download_id
      report
    end)

    Watch.check(row, writer(row))
  end

  defp paused, do: {:ok, %{state: :downloading, progress: 0.0, speed: nil, client_paused: true}}
  defp running, do: {:ok, %{state: :downloading, progress: 0.0, speed: nil, eta: nil}}

  defp assert_about(actual, expected) do
    assert abs(DateTime.diff(actual, expected)) <= 5,
           "expected #{actual} within 5 s of #{expected}"
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)

  # What each real adapter's `status/1` reports on a stubbed response, for a download its client
  # holds on purpose (#1602) and, as a control, for a stalled torrent. Each runs in the test
  # process, which owns the `Req.Test` stub; the tick then hands the report to the client mock.
  @holds [:qbittorrent_stopped, :transmission_stopped, :nzbget_paused]

  defp adapter_report(:qbittorrent_stopped), do: qbittorrent_report("stoppedDL")
  defp adapter_report(:qbittorrent_stalled), do: qbittorrent_report("stalledDL")

  defp adapter_report(:transmission_stopped) do
    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
      case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("x-transmission-session-id", "session")
          |> Plug.Conn.send_resp(409, "")

        [_session] ->
          Req.Test.json(conn, %{
            "result" => "success",
            "arguments" => %{
              "torrents" => [
                %{
                  "hashString" => "held",
                  "status" => 0,
                  "percentDone" => 0.4,
                  "rateDownload" => 0,
                  "eta" => -1,
                  "peersSendingToUs" => 0,
                  "error" => 0,
                  "errorString" => ""
                }
              ]
            }
          })
      end
    end)

    Transmission.status("held")
  end

  defp adapter_report(:nzbget_paused) do
    Req.Test.stub(Cinder.NzbgetStub, fn conn ->
      Req.Test.json(conn, %{
        "id" => 1,
        "error" => nil,
        "result" => [
          %{
            "NZBID" => 42,
            "Status" => "PAUSED",
            "Health" => 1000,
            "CriticalHealth" => 900,
            "FileSizeHi" => 0,
            "FileSizeLo" => 100,
            "RemainingSizeHi" => 0,
            "RemainingSizeLo" => 100
          }
        ]
      })
    end)

    Nzbget.status("42")
  end

  defp adapter_report(:nzbget_queued) do
    Req.Test.stub(Cinder.NzbgetStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      result =
        case Jason.decode!(body)["method"] do
          "listgroups" -> [%{"NZBID" => 42, "Status" => "QUEUED", "MaxPriority" => 0}]
          "status" -> %{"DownloadPaused" => true}
        end

      Req.Test.json(conn, %{"id" => 1, "error" => nil, "result" => result})
    end)

    Nzbget.status("42")
  end

  defp qbittorrent_report(state) do
    Req.Test.stub(Cinder.QBittorrentStub, fn
      %{request_path: "/api/v2/auth/login"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "SID=session; path=/")
        |> Req.Test.text("Ok.")

      conn ->
        Req.Test.json(conn, [
          %{"state" => state, "progress" => 0.0, "dlspeed" => 0, "num_seeds" => 0}
        ])
    end)

    QBittorrent.status("held")
  end

  # A running row 31 minutes past both clocks: past the no-seeders window, inside the cap.
  defp aged(row) do
    seed(row, %{
      download_paused_at: nil,
      download_progress: 0.0,
      download_speed: nil,
      updated_at: minutes_ago(31),
      download_progress_at: minutes_ago(31)
    })
  end

  defp blocklist_rows,
    do: Repo.aggregate(BlockedRelease, :count) + Repo.aggregate(BookBlockedRelease, :count)

  for kind <- @kinds do
    @kind kind

    describe "#{kind}" do
      test "the first paused tick marks the row, and later ones write nothing" do
        row = @kind |> row() |> seed(%{updated_at: hours_ago(1), download_progress: 0.0})

        assert tick(row, paused()) == :downloading
        marked = Repo.reload!(row)
        assert_about(marked.download_paused_at, DateTime.utc_now())

        frozen = seed(marked, %{updated_at: hours_ago(2)})
        assert tick(frozen, paused()) == :downloading
        assert Repo.reload!(frozen).updated_at == frozen.updated_at
        assert Repo.reload!(frozen).download_paused_at == marked.download_paused_at
      end

      test "a 42 h pause after 23 h of running leaves one hour on the cap" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: hours_ago(65),
            download_paused_at: hours_ago(42)
          })

        assert tick(row, paused()) == :downloading
        assert tick(Repo.reload!(row), running()) == :downloading

        resumed = Repo.reload!(row)
        assert resumed.download_paused_at == nil
        assert_about(resumed.download_progress_at, hours_ago(23))
      end

      test "25 h of running split across a pause still stalls" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: hours_ago(67),
            download_paused_at: hours_ago(42)
          })

        assert tick(row, running()) == :stalled
      end

      test "a first sighting past the cap survives the resume" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: DateTime.add(hours_ago(24), -300, :second)
          })

        assert tick(row, paused()) == :downloading
        assert Repo.reload!(row).download_paused_at == Repo.reload!(row).download_progress_at

        assert tick(Repo.reload!(row), running()) == :downloading
        assert_about(Repo.reload!(row).download_progress_at, DateTime.utc_now())
      end

      test "a clock that just crossed the cap gets no new window from a pause" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: DateTime.add(hours_ago(24), -5, :second)
          })

        assert tick(row, paused()) == :downloading
        assert tick(Repo.reload!(row), running()) == :stalled
      end

      test "an unreachable tick keeps the pause, and the later resume still credits it" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_eta: 60,
            download_progress_at: hours_ago(30),
            download_paused_at: hours_ago(28)
          })

        assert {:unreachable, :econnrefused} = tick(row, {:error, :econnrefused})
        kept = Repo.reload!(row)
        assert kept.download_paused_at == row.download_paused_at
        assert kept.download_eta == nil

        assert tick(kept, running()) == :downloading
        assert_about(Repo.reload!(row).download_progress_at, hours_ago(2))
      end

      test "progress on the resume tick sets the clock to now" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.1,
            download_progress_at: hours_ago(30),
            download_paused_at: hours_ago(28)
          })

        report = {:ok, %{state: :downloading, progress: 0.2, speed: nil}}
        assert tick(row, report) == :downloading

        resumed = Repo.reload!(row)
        assert resumed.download_paused_at == nil
        assert_about(resumed.download_progress_at, DateTime.utc_now())
      end

      test "a torrent or usenet client's hold past the no-seeders window keeps the download" do
        row = row(@kind)

        for name <- @holds do
          assert {name, tick(aged(row), adapter_report(name))} == {name, :downloading}
          assert {name, match?(%DateTime{}, Repo.reload!(row).download_paused_at)} == {name, true}
        end
      end

      test "a stalled torrent with no seeds is still reaped past the no-seeders window" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            updated_at: minutes_ago(31),
            download_progress_at: minutes_ago(31)
          })

        assert tick(row, adapter_report(:qbittorrent_stalled)) == :stalled
      end

      test "the tick that ends a 3 h hold starts a full no-seeders window" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_speed: 0,
            updated_at: hours_ago(3),
            download_progress_at: hours_ago(3),
            download_paused_at: hours_ago(3)
          })

        dead = {:ok, %{state: :downloading, progress: 0.0, speed: 0, seeders: 0}}
        assert tick(row, dead) == :downloading

        resumed = Repo.reload!(row)
        assert resumed.download_paused_at == nil
        assert_about(resumed.updated_at, DateTime.utc_now())

        assert tick(seed(resumed, %{updated_at: minutes_ago(29)}), dead) == :downloading
        assert tick(seed(resumed, %{updated_at: minutes_ago(31)}), dead) == :stalled
      end

      test "the tick that ends a 3 h hold of a seeded torrent starts a full 2 h window" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_speed: 0,
            updated_at: hours_ago(3),
            download_progress_at: hours_ago(3),
            download_paused_at: hours_ago(3)
          })

        seeded = {:ok, %{state: :downloading, progress: 0.0, speed: 0, seeders: 3}}
        assert tick(row, seeded) == :downloading

        resumed = Repo.reload!(row)
        assert tick(seed(resumed, %{updated_at: minutes_ago(119)}), seeded) == :downloading
        assert tick(seed(resumed, %{updated_at: minutes_ago(121)}), seeded) == :stalled
      end

      test "an NZBGet job waiting on paused downloads past the 24 h cap keeps the download" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            updated_at: hours_ago(25),
            download_progress_at: hours_ago(25)
          })

        assert tick(row, adapter_report(:nzbget_queued)) == :downloading
        assert %DateTime{} = Repo.reload!(row).download_paused_at
      end
    end
  end

  # #1602: each poller, on each real adapter's report for a held download past the no-seeders
  # window, removes nothing and blocklists nothing. A stalled torrent's report is the control: the
  # same poller removes and blocklists it, so the refutes watch the right calls and rows.
  describe "the pollers on a held download" do
    defp poll(%Movie{}) do
      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()
      stop_supervised!(Poller)
    end

    defp poll(%Grab{}) do
      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()
      stop_supervised!(TvPoller)
    end

    defp poll(%BookGrab{}) do
      start_supervised!({BookPoller, interval: 60_000})
      assert :ok = BookPoller.poll()
      stop_supervised!(BookPoller)
    end

    defp poll_with(row, report) do
      test_pid = self()
      stub(@client, :status, fn id when id == row.download_id -> report end)

      stub(@client, :remove, fn id, _opts ->
        send(test_pid, {:removed, id})
        :ok
      end)

      poll(row)
    end

    for kind <- @kinds do
      @kind kind

      test "the #{kind} poller removes and blocklists nothing" do
        row = row(@kind)

        for name <- @holds do
          poll_with(aged(row), adapter_report(name))

          refute_received {:removed, _id}, inspect(name)
          assert {name, blocklist_rows()} == {name, 0}
          assert {name, match?(%DateTime{}, Repo.reload!(row).download_paused_at)} == {name, true}
        end

        poll_with(aged(row), adapter_report(:qbittorrent_stalled))
        assert_received {:removed, "job-" <> _}
        assert blocklist_rows() == 1
      end
    end
  end

  describe "the end of a pause" do
    test "a movie's move to import clears it" do
      movie = :movie |> row() |> seed(%{download_paused_at: hours_ago(1)})

      assert {:ok, %Movie{status: :downloaded, download_paused_at: nil}} =
               MovieLifecycle.mark_downloaded(movie, "/downloads/M")

      assert Repo.reload!(movie).download_paused_at == nil
    end

    test "a TV grab's completion clears it, from a copy that never saw the pause" do
      grab = row(:grab)
      seed(grab, %{download_paused_at: hours_ago(1)})

      assert {:ok, _} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert Repo.reload!(grab).download_paused_at == nil
    end

    test "a book grab's completion clears it" do
      grab = :book |> row() |> seed(%{download_paused_at: hours_ago(1)})

      assert {:ok, %BookGrab{download_paused_at: nil}} =
               Books.Grabs.mark_downloaded(grab, "/downloads/book")
    end

    test "a metrics write and a counted strike during the pause keep it" do
      at = hours_ago(1)

      movie =
        :movie
        |> row()
        |> seed(%{download_paused_at: at, download_speed: 100, import_attempts: 0})

      assert {:ok, tracked} = MovieLifecycle.track(movie, %{download_speed: nil})
      assert tracked.download_paused_at == at

      assert {:ok, struck} =
               MovieLifecycle.record_failure(tracked, {:failed, :download_not_found})

      assert struck.status == :downloading
      assert Repo.reload!(movie).download_paused_at == at
    end

    test "a stale track after the movie's download changed writes nothing" do
      movie = :movie |> row() |> seed(%{download_paused_at: hours_ago(30)})
      clock = hours_ago(1)
      current = seed(movie, %{download_id: "job-new", download_progress_at: clock})

      assert {:error, :stale_status} = MovieLifecycle.track(movie, %{client_paused: false})

      assert Repo.reload!(current).download_progress_at == clock
      assert Repo.reload!(current).download_paused_at == current.download_paused_at
    end
  end

  describe "the movie poller" do
    test "removes and blocklists nothing while the client is paused past the cap" do
      movie =
        :movie
        |> row()
        |> seed(%{download_progress: 0.0, download_progress_at: hours_ago(30)})

      test_pid = self()
      stub(@client, :status, fn "job-movie" -> paused() end)

      stub(@client, :remove, fn id, _opts ->
        send(test_pid, {:removed, id})
        :ok
      end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      refute_received {:removed, _id}
      polled = Repo.reload!(movie)
      assert polled.status == :downloading
      assert Catalog.blocked_release_titles(polled) == []
    end
  end
end
