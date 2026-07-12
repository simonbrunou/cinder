defmodule Cinder.Acquisition.Indexer.ProwlarrTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Prowlarr

  test "search/1 queries by IMDb id and normalizes results, falling back to magnetUrl" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["query"] == "{ImdbId:tt1375666}"
      assert conn.params["type"] == "movie"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      Req.Test.json(conn, [
        %{
          "title" => "Inception.2010.1080p.BluRay.x264-RARBG",
          "size" => 8_000_000_000,
          "downloadUrl" => "http://prowlarr:9696/file/1",
          "seeders" => 50,
          "protocol" => "torrent"
        },
        %{
          "title" => "Inception.2010.2160p.WEB-DL-GRP",
          "size" => 40_000_000_000,
          "downloadUrl" => nil,
          "magnetUrl" => "magnet:?xt=urn:btih:abc",
          "seeders" => 10
        },
        %{
          "title" => "Inception.2010.1080p.WEB-DL-GRP",
          "size" => 9_000_000_000,
          "downloadUrl" => "http://prowlarr:9696/getnzb/3",
          "protocol" => "usenet"
        },
        %{
          "title" => "Inception.2010.720p.WEB-DL-GRP",
          "size" => 4_000_000_000,
          "downloadUrl" => "https://provider.test/file/4",
          "protocol" => "torrent"
        }
      ])
    end)

    assert {:ok, results} = Prowlarr.search("tt1375666")

    assert results == [
             %{
               title: "Inception.2010.1080p.BluRay.x264-RARBG",
               size: 8_000_000_000,
               download_url: "http://prowlarr:9696/file/1",
               download_url_origin: "http://prowlarr:9696",
               protocol: :torrent
             },
             %{
               title: "Inception.2010.2160p.WEB-DL-GRP",
               size: 40_000_000_000,
               download_url: "magnet:?xt=urn:btih:abc",
               download_url_origin: nil,
               protocol: :torrent
             },
             %{
               title: "Inception.2010.1080p.WEB-DL-GRP",
               size: 9_000_000_000,
               download_url: "http://prowlarr:9696/getnzb/3",
               download_url_origin: "http://prowlarr:9696",
               protocol: :usenet
             },
             %{
               title: "Inception.2010.720p.WEB-DL-GRP",
               size: 4_000_000_000,
               download_url: "https://provider.test/file/4",
               download_url_origin: nil,
               protocol: :torrent
             }
           ]
  end

  test "search_tv/3 queries tvsearch by TVDB id + season and normalizes results" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["query"] == "{TvdbId:1396}{Season:1}"
      assert conn.params["type"] == "tvsearch"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      Req.Test.json(conn, [
        %{
          "title" => "Breaking.Bad.S01E01.1080p.BluRay.x264-GRP",
          "size" => 2_000_000_000,
          "downloadUrl" => "http://prowlarr:9696/file/1",
          "seeders" => 30,
          "protocol" => "torrent"
        }
      ])
    end)

    assert {:ok, [result]} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert result == %{
             title: "Breaking.Bad.S01E01.1080p.BluRay.x264-GRP",
             size: 2_000_000_000,
             download_url: "http://prowlarr:9696/file/1",
             download_url_origin: "http://prowlarr:9696",
             protocol: :torrent
           }
  end

  test "search_tv/3 falls back to a free-text title query when tvdb_id is nil" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "Breaking Bad {Season:2}"
      assert conn.params["type"] == "tvsearch"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_tv(nil, "Breaking Bad", 2)
  end

  test "search_tv/3 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    assert {:error, {:prowlarr_status, 500}} = Prowlarr.search_tv(1396, "Breaking Bad", 1)
  end

  test "search/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    assert {:error, {:prowlarr_status, 500}} = Prowlarr.search("tt1375666")
  end

  test "search/1 returns an error (not a raise) on a 200 that isn't a list" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Req.Test.json(conn, %{"unexpected" => true})
    end)

    assert {:error, :unexpected_response} = Prowlarr.search("tt1375666")
  end

  test "health/0 pings /api/v1/health with the api key and returns :ok on 200" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/health"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      Req.Test.json(conn, [])
    end)

    assert :ok = Prowlarr.health()
  end

  test "health/0 returns an error tuple on a non-2xx status" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.text("down")
    end)

    assert {:error, {:prowlarr_status, 503}} = Prowlarr.health()
  end

  test "search/1 does not forward its API key across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "x-api-key")})
          Req.Test.json(conn, [])
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/search")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:prowlarr_status, ^status}} = Prowlarr.search("tt1375666")
      refute_received {:attacker_called, _}
    end
  end

  test "search/1 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Prowlarr.search("tt1375666")
  end
end
