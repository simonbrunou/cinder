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
          "downloadUrl" => "http://prowlarr/file/1",
          "seeders" => 50
        },
        %{
          "title" => "Inception.2010.2160p.WEB-DL-GRP",
          "size" => 40_000_000_000,
          "downloadUrl" => nil,
          "magnetUrl" => "magnet:?xt=urn:btih:abc",
          "seeders" => 10
        }
      ])
    end)

    assert {:ok, results} = Prowlarr.search("tt1375666")

    assert results == [
             %{
               title: "Inception.2010.1080p.BluRay.x264-RARBG",
               size: 8_000_000_000,
               download_url: "http://prowlarr/file/1",
               seeders: 50
             },
             %{
               title: "Inception.2010.2160p.WEB-DL-GRP",
               size: 40_000_000_000,
               download_url: "magnet:?xt=urn:btih:abc",
               seeders: 10
             }
           ]
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
end
