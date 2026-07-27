defmodule Cinder.Library.MigrationSource.RadarrTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.MigrationSource.Radarr

  setup do
    original = Application.get_env(:cinder, Radarr)
    on_exit(fn -> Application.put_env(:cinder, Radarr, original) end)
    :ok
  end

  test "snapshot/0 normalizes movie identities and translates movie-file paths" do
    local = Path.join(System.tmp_dir!(), "cinder-radarr-test")
    File.mkdir_p!(local)

    Application.put_env(:cinder, Radarr,
      base_url: "http://radarr:7878",
      api_key: "test-key",
      remote_path_prefix: "/movies",
      local_path_prefix: local,
      req_options: [plug: {Req.Test, Cinder.RadarrStub}, retry: false]
    )

    Req.Test.stub(Cinder.RadarrStub, fn conn ->
      assert conn.request_path == "/api/v3/movie"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      Req.Test.json(conn, [
        %{
          "id" => 1,
          "tmdbId" => 10,
          "imdbId" => "tt0000010",
          "movieFileId" => 501,
          "path" => "/movies/Movie One",
          "movieFile" => %{
            "id" => 501,
            "relativePath" => "Movie One.mkv",
            "size" => 1_000
          }
        },
        %{"id" => 2, "tmdbId" => 0, "imdbId" => "tt0000020", "movieFileId" => 0}
      ])
    end)

    assert {:ok, snapshot} = Radarr.snapshot()

    assert snapshot.movies == [
             %{provider_id: 1, tmdb_id: 10, imdb_id: "tt0000010", file_id: 501},
             %{provider_id: 2, tmdb_id: nil, imdb_id: "tt0000020", file_id: nil}
           ]

    assert snapshot.files == [
             %{
               provider_id: 501,
               kind: :movie,
               path: Path.join(local, "Movie One/Movie One.mkv"),
               size: 1_000
             }
           ]
  end

  test "health/0 uses the authenticated bounded status probe" do
    Req.Test.stub(Cinder.RadarrStub, fn conn ->
      assert conn.request_path == "/api/v3/system/status"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      Req.Test.json(conn, %{"version" => "5.0"})
    end)

    assert :ok = Radarr.health()
  end
end
