defmodule Cinder.Download.WatchTest do
  @moduledoc """
  The download watch's one verdict per in-flight download per tick, for every kind at once: the
  movie, upgrade, TV and book pollers all reach the client through `Watch.check/2`, so the rules
  that used to be copied into each of them are pinned here. The pollers' own tests cover only
  what each verdict does to their kind.

  `async: false` because the stall-reaper rows switch `Cinder.Download.StallReaper` on through
  application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Download.{StallReaper, Watch}

  setup :verify_on_exit!

  @updated_at ~U[2026-01-01 00:00:00Z]

  defp download(attrs \\ %{}) do
    Map.merge(%{download_id: "dl-1", download_protocol: :torrent, updated_at: @updated_at}, attrs)
  end

  # Stands in for the kind's metrics writer: reports each write to the test and answers with the
  # progress clock the row would carry afterwards.
  defp track(progress_at \\ @updated_at) do
    test_pid = self()

    fn download, attrs ->
      send(test_pid, {:tracked, download.download_id, attrs})
      {:ok, %{download_progress_at: progress_at}}
    end
  end

  @usenet Cinder.Download.SabnzbdClientMock

  defp status(result, client \\ Cinder.Download.ClientMock),
    do: expect(client, :status, fn "dl-1" -> result end)

  defp files(names, client \\ Cinder.Download.ClientMock),
    do: expect(client, :files, fn "dl-1" -> {:ok, names} end)

  # The test env infers an import root, and the test path policy ignores roots and walks through
  # the filesystem mock: a directory answers `find_files/1`, anything else is a single-file
  # download.
  defp disk(dir, entries) do
    stub(Cinder.Library.FilesystemMock, :dir?, &(&1 == dir))
    stub(Cinder.Library.FilesystemMock, :find_files, fn ^dir -> {:ok, entries} end)
  end

  describe "a completed download" do
    test "is completed with its path once its file list and its files on disk are clean" do
      status({:ok, %{state: :completed, progress: 1.0, content_path: "/dl/Movie"}})
      files(["Movie/Movie.mkv"])
      disk("/dl/Movie", [{"/dl/Movie/Movie.mkv", 4_000_000_000}])

      assert Watch.check(download(), track()) == {:completed, "/dl/Movie"}
      refute_received {:tracked, _id, _attrs}
    end

    # A fake is small enough to finish between two ticks, so the first status a poller ever sees
    # for it is :completed. Vetting only while :downloading lets exactly that payload reach import.
    test "is blocked content when its file list carries only an executable" do
      status({:ok, %{state: :completed, progress: 1.0, content_path: "/dl/Movie"}})
      files(["Movie/Movie.mkv.lnk", "Movie/readme.txt"])

      assert Watch.check(download(), track()) ==
               {:blocked_content, "download contains Movie.mkv.lnk"}

      refute_received {:tracked, _id, _attrs}
    end

    # SABnzbd has no file list for a job already in history, so a usenet fake that finished
    # between two ticks reaches :completed with nothing for the client check to read. The files
    # are on disk under the content path by then.
    test "is blocked content when the client has no file list but the disk carries a fake" do
      status({:ok, %{state: :completed, progress: 1.0, content_path: "/dl/Movie"}}, @usenet)
      files([], @usenet)
      disk("/dl/Movie", [{"/dl/Movie/Movie.mkv.lnk", 1_024}, {"/dl/Movie/readme.txt", 64}])

      assert Watch.check(download(%{download_protocol: :usenet}), track()) ==
               {:blocked_content, "download contains Movie.mkv.lnk"}
    end

    test "is blocked content when its content path is a single blocked file" do
      status(
        {:ok, %{state: :completed, progress: 1.0, content_path: "/dl/Movie.mkv.lnk"}},
        @usenet
      )

      files([], @usenet)
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Movie.mkv.lnk" -> false end)

      assert Watch.check(download(%{download_protocol: :usenet}), track()) ==
               {:blocked_content, "download contains Movie.mkv.lnk"}
    end

    # Best-effort like the client check: a walk that could not run is no opinion.
    test "is completed when its files on disk cannot be listed" do
      status({:ok, %{state: :completed, progress: 1.0, content_path: "/dl/Movie"}}, @usenet)
      files([], @usenet)
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Movie" -> true end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Movie" -> {:error, :eacces} end)

      assert Watch.check(download(%{download_protocol: :usenet}), track()) ==
               {:completed, "/dl/Movie"}
    end

    # A client can report the whole downloads folder as the content path, whose walk finds other
    # downloads' media. The client's own file list still blocks the fake.
    test "is blocked content on the client's file list whatever the disk holds" do
      status({:ok, %{state: :completed, progress: 1.0, content_path: "/dl"}})
      files(["setup.exe"])
      disk("/dl", [{"/dl/setup.exe", 1_024}, {"/dl/Other/Other.mkv", 4_000_000_000}])

      assert Watch.check(download(), track()) == {:blocked_content, "download contains setup.exe"}
    end
  end

  describe "a download still in flight" do
    # Zero speed and zero seeders: a dead swarm the reaper's short window is built for.
    @dead_swarm %{state: :downloading, progress: 0.25, speed: 0, eta: nil, seeders: 0}

    test "records its progress and keeps downloading" do
      status({:ok, %{state: :downloading, progress: 0.5, speed: 1_000, eta: 60, seeders: 9}})
      files(["Movie/Movie.mkv"])

      assert Watch.check(download(), track()) == :downloading

      assert_received {:tracked, "dl-1",
                       %{download_progress: 0.5, download_speed: 1_000, download_eta: 60}}
    end

    test "is blocked content before any progress is recorded" do
      status({:ok, %{state: :downloading, progress: 0.5, speed: 1_000}})
      files(["Movie/setup.exe"])

      assert Watch.check(download(), track()) == {:blocked_content, "download contains setup.exe"}
      refute_received {:tracked, _id, _attrs}
    end

    test "is only downloading while the stall reaper is switched off" do
      status({:ok, @dead_swarm})
      files([])

      assert Watch.check(download(), track()) == :downloading
      assert_received {:tracked, "dl-1", _attrs}
    end

    test "is stalled once the stall reaper is switched on, after its progress is recorded" do
      stall_reaper(enabled: true, no_seeders_timeout: :timer.minutes(30))
      status({:ok, @dead_swarm})
      files([])

      assert Watch.check(download(), track()) == :stalled
      assert_received {:tracked, "dl-1", %{download_progress: 0.25}}
    end

    # The absolute cap reads the progress clock. After an outage longer than the cap, the clock the
    # row carried at tick start is stale by definition; only the clock the metrics write returns
    # knows whether this tick's status was real forward motion.
    test "reaps on the progress clock the metrics write returns, not the tick-start one" do
      stall_reaper(enabled: true, max_downloading_timeout: :timer.hours(24))
      status({:ok, %{state: :downloading, progress: 0.5, speed: 1_000, seeders: 9}})
      files([])

      just_advanced = DateTime.utc_now()
      assert Watch.check(download(), track(just_advanced)) == :downloading

      status({:ok, %{state: :downloading, progress: 0.5, speed: 1_000, seeders: 9}})
      files([])

      assert Watch.check(download(), track(@updated_at)) == :stalled
    end

    test "is not reaped when its progress could not be recorded" do
      stall_reaper(enabled: true, no_seeders_timeout: :timer.minutes(30))
      status({:ok, @dead_swarm})
      files([])

      rejected = fn _download, _attrs -> {:error, :stale_grab} end

      log = capture_log(fn -> assert Watch.check(download(), rejected) == :downloading end)
      assert log =~ "dl-1 progress not recorded: :stale_grab"
    end
  end

  describe "a failed download" do
    # One reason per client answer, whatever the kind: the reason atoms are persisted (blocklist
    # rows, book hold reasons), so they cannot differ by poller. Every row here is a SUCCESSFUL
    # client answer, never vetted (there is no payload to vet) and never tracked; the pollers bound
    # how many ticks they spend on it before acting.
    for {name, answer, verdict} <- [
          {"completed with no content path", {:ok, %{state: :completed, content_path: nil}},
           {:failed, :no_content_path}},
          {"completed with an empty content path", {:ok, %{state: :completed, content_path: ""}},
           {:failed, :no_content_path}},
          {"completed with no content path key", {:ok, %{state: :completed, progress: 1.0}},
           {:failed, :no_content_path}},
          {"an error that keeps the client's detail",
           {:ok, %{state: :error, reason: "Paused on duplicate"}},
           {:failed, {:download_error, "Paused on duplicate"}}},
          {"an error with a blank detail", {:ok, %{state: :error, reason: ""}},
           {:failed, :download_error}},
          {"an error with no detail", {:ok, %{state: :error, progress: 0.1}},
           {:failed, :download_error}},
          {"a job the client no longer knows", {:error, :not_found},
           {:failed, :download_not_found}}
        ] do
      @answer answer
      @verdict verdict

      test "#{name}" do
        status(@answer)

        assert {:failed, reason} = Watch.check(download(), track())
        assert {:failed, reason} == @verdict
        # The movie and TV parks blocklist on this predicate, so every reason the watch produces
        # must pass it, in the shape the verdict carries it.
        assert Watch.failure?(reason)
        refute_received {:tracked, _id, _attrs}
      end
    end
  end

  describe "failure?/1" do
    # The verdicts no poller may blocklist as a download failure, and the names this vocabulary
    # retired (#755): a row still carrying one was renamed by the 20261020 migration.
    for reason <- [
          :stalled,
          :no_client,
          :blocked_content,
          {:blocked_content, "setup.exe"},
          :no_files_matched,
          :torrent_not_found,
          :missing_content_path,
          :download_missing
        ] do
      @reason reason

      test "is false for #{inspect(reason)}" do
        refute Watch.failure?(@reason)
      end
    end
  end

  describe "reason_code/1" do
    # Blocklist rows are written on the code: a client's detail never reaches a row's reason.
    test "drops the detail a reason carries" do
      assert Watch.reason_code({:download_error, "Paused on duplicate"}) == :download_error
      assert Watch.reason_code({:blocked_content, "setup.exe"}) == :blocked_content
    end

    test "keeps a bare code" do
      assert Watch.reason_code(:download_not_found) == :download_not_found
      assert Watch.reason_code(:no_files_matched) == :no_files_matched
    end
  end

  describe "a download the client cannot answer for" do
    test "has no client when none is configured for its protocol" do
      # No ClientMock expectation: reaching any client would fail this test.
      assert Watch.check(download(%{download_protocol: :ftp}), track()) == :no_client
      refute_received {:tracked, _id, _attrs}
    end

    # A slow or restarting client is not evidence about the download, so nothing fails; but the
    # speed and ETA on screen are no longer live, so they are cleared while progress is kept.
    test "is unreachable when the status call fails, and its live estimates are cleared" do
      status({:error, :timeout})

      assert Watch.check(download(), track()) == {:unreachable, :timeout}
      assert_received {:tracked, "dl-1", %{download_speed: nil, download_eta: nil} = attrs}
      refute Map.has_key?(attrs, :download_progress)
    end

    test "is unreachable when the client answers with a state outside the contract" do
      status({:ok, %{state: :queued, progress: 0.0}})

      assert Watch.check(download(), track()) ==
               {:unreachable, {:unexpected_status, %{state: :queued, progress: 0.0}}}

      assert_received {:tracked, "dl-1", %{download_speed: nil, download_eta: nil}}
    end

    # The content check is best-effort: a client that cannot list files has no opinion, and a
    # check that could not run must never be what kills a download.
    test "is still downloading when the client cannot list its files" do
      status({:ok, %{state: :downloading, progress: 0.5, speed: 1_000}})
      expect(Cinder.Download.ClientMock, :files, fn "dl-1" -> {:error, :econnrefused} end)

      assert Watch.check(download(), track()) == :downloading
    end

    test "is asked of the protocol's own client" do
      status({:ok, %{state: :completed, content_path: "/dl/Movie"}}, @usenet)
      files(["Movie.mkv"], @usenet)
      disk("/dl/Movie", [{"/dl/Movie/Movie.mkv", 4_000_000_000}])

      assert Watch.check(download(%{download_protocol: :usenet}), track()) ==
               {:completed, "/dl/Movie"}
    end
  end

  defp stall_reaper(opts) do
    saved = Application.get_env(:cinder, StallReaper)
    Application.put_env(:cinder, StallReaper, opts)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, StallReaper, saved),
        else: Application.delete_env(:cinder, StallReaper)
    end)
  end
end
