defmodule Cinder.Library.MigrationSource.SonarrTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.MigrationSource.Sonarr

  setup do
    original = Application.get_env(:cinder, Sonarr)
    on_exit(fn -> Application.put_env(:cinder, Sonarr, original) end)
    :ok
  end

  test "snapshot/0 from a Task.async child of the stub's owner returns the stubbed snapshot" do
    stub_one_series()

    # The child reaches the stub's owner only through `$callers`: it owns nothing itself.
    task = Task.async(fn -> Sonarr.snapshot() end)

    assert {:ok, snapshot} = Task.await(task)
    assert snapshot.diagnostics == []
    assert snapshot.series == [%{provider_id: 11, tvdb_id: 100}]

    assert Enum.map(snapshot.episodes, &Map.take(&1, [:provider_id, :tvdb_id, :file_id])) == [
             %{provider_id: 21, tvdb_id: 1001, file_id: 601}
           ]

    assert snapshot.files == [
             %{provider_id: 601, kind: :episode, path: "/tv/Show/Show.S01E01.mkv", size: 3_000}
           ]
  end

  # The request task that finds no stub logs its crash.
  @tag :capture_log
  test "snapshot/0 keeps a series whose fetch finds no stub as a diagnostic in a live caller" do
    # One expectation answers the series list; the episode fetch then finds no stub and the
    # plug lookup raises in the request task.
    Req.Test.expect(Cinder.SonarrStub, fn conn ->
      assert conn.request_path == "/api/v3/series"
      Req.Test.json(conn, [%{"id" => 11, "tvdbId" => 100, "title" => "Show"}])
    end)

    # `Task.await/1` returns only when the linked caller lived to send its result.
    task = Task.async(fn -> Sonarr.snapshot() end)
    result = Task.await(task)

    assert {:ok,
            %{
              series: [],
              episodes: [],
              files: [],
              diagnostics: [
                %{
                  kind: :series,
                  provider_id: 11,
                  reason:
                    {:series_snapshot_failed, {%RuntimeError{message: message}, _stacktrace}}
                }
              ]
            }} = result

    assert message == "no mock or stub for Cinder.SonarrStub"
  end

  @tag :capture_log
  test "snapshot/0 with no stub owner anywhere returns an error and its caller exits normally" do
    stub_one_series()
    test_pid = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           # This task's `$callers` reach the test process, which owns the stub. Without them, no
           # process in its chain owns one.
           Process.delete(:"$callers")

           # Wait for the monitor, so the exit reason is never `:noproc`.
           receive do
             :go -> send(test_pid, {:snapshot, Sonarr.snapshot()})
           end
         end},
        id: make_ref()
      )

    ref = Process.monitor(pid)
    send(pid, :go)

    # The series-list request fails in the plug lookup, before the per-series stream starts.
    assert_receive {:snapshot, {:error, {%RuntimeError{message: message}, _stacktrace}}}, 5_000
    assert message =~ "cannot find mock/stub Cinder.SonarrStub"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "snapshot/0 normalizes TVDB episodes and de-duplicates a shared episodeFileId" do
    Req.Test.stub(Cinder.SonarrStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      case conn.request_path do
        "/api/v3/series" ->
          Req.Test.json(conn, [%{"id" => 11, "tvdbId" => 100, "path" => "/tv/Show"}])

        "/api/v3/episode" ->
          assert conn.params["seriesId"] == "11"
          assert conn.params["includeEpisodeFile"] == "true"

          file = %{"id" => 601, "relativePath" => "Show.S01E01-E02.mkv", "size" => 3_000}

          Req.Test.json(conn, [
            %{
              "id" => 21,
              "seriesId" => 11,
              "tvdbId" => 1001,
              "seasonNumber" => 1,
              "episodeNumber" => 1,
              "episodeFileId" => 601,
              "episodeFile" => file
            },
            %{
              "id" => 22,
              "seriesId" => 11,
              "tvdbId" => 1002,
              "seasonNumber" => 1,
              "episodeNumber" => 2,
              "episodeFileId" => 601,
              "episodeFile" => file
            }
          ])
      end
    end)

    assert {:ok, snapshot} = Sonarr.snapshot()
    assert snapshot.series == [%{provider_id: 11, tvdb_id: 100}]

    assert Enum.map(snapshot.episodes, &Map.take(&1, [:provider_id, :tvdb_id, :file_id])) == [
             %{provider_id: 21, tvdb_id: 1001, file_id: 601},
             %{provider_id: 22, tvdb_id: 1002, file_id: 601}
           ]

    assert snapshot.files == [
             %{
               provider_id: 601,
               kind: :episode,
               path: "/tv/Show/Show.S01E01-E02.mkv",
               size: 3_000
             }
           ]
  end

  test "health/0 uses the authenticated bounded status probe" do
    Req.Test.stub(Cinder.SonarrStub, fn conn ->
      assert conn.request_path == "/api/v3/system/status"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      Req.Test.json(conn, %{"version" => "4.0"})
    end)

    assert :ok = Sonarr.health()
  end

  defp stub_one_series do
    Req.Test.stub(Cinder.SonarrStub, fn conn ->
      case conn.request_path do
        "/api/v3/series" ->
          Req.Test.json(conn, [%{"id" => 11, "tvdbId" => 100, "path" => "/tv/Show"}])

        "/api/v3/episode" ->
          Req.Test.json(conn, [
            %{
              "id" => 21,
              "seriesId" => 11,
              "tvdbId" => 1001,
              "seasonNumber" => 1,
              "episodeNumber" => 1,
              "episodeFileId" => 601,
              "episodeFile" => %{
                "id" => 601,
                "relativePath" => "Show.S01E01.mkv",
                "size" => 3_000
              }
            }
          ])
      end
    end)
  end
end
