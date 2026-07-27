defmodule Cinder.Library.MigrationSource.SonarrTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.MigrationSource.Sonarr

  setup do
    original = Application.get_env(:cinder, Sonarr)
    on_exit(fn -> Application.put_env(:cinder, Sonarr, original) end)
    :ok
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
end
