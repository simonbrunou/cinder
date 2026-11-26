defmodule Cinder.Acquisition.IndexerSource.ProwlarrTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.{NzbFixture, TorrentFixture}

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
               protocol: :torrent,
               category_ids: [],
               indexer_id: nil,
               indexer_source: "prowlarr",
               indexer_name: nil,
               published_at: nil
             },
             %{
               title: "Inception.2010.2160p.WEB-DL-GRP",
               size: 40_000_000_000,
               download_url: "magnet:?xt=urn:btih:abc",
               download_url_origin: nil,
               protocol: :torrent,
               category_ids: [],
               indexer_id: nil,
               indexer_source: "prowlarr",
               indexer_name: nil,
               published_at: nil
             },
             %{
               title: "Inception.2010.1080p.WEB-DL-GRP",
               size: 9_000_000_000,
               download_url: "http://prowlarr:9696/getnzb/3",
               download_url_origin: "http://prowlarr:9696",
               protocol: :usenet,
               category_ids: [],
               indexer_id: nil,
               indexer_source: "prowlarr",
               indexer_name: nil,
               published_at: nil
             },
             %{
               title: "Inception.2010.720p.WEB-DL-GRP",
               size: 4_000_000_000,
               download_url: "https://provider.test/file/4",
               download_url_origin: nil,
               protocol: :torrent,
               category_ids: [],
               indexer_id: nil,
               indexer_source: "prowlarr",
               indexer_name: nil,
               published_at: nil
             }
           ]
  end

  # #1644: the name is for display only, so anything but a non-blank string reads as no name.
  test "search/1 normalizes the indexer name and marks every result a Prowlarr one" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Req.Test.json(
        conn,
        for {indexer, n} <- Enum.with_index([:absent, "NZBgeek", "", "  ", 42, nil, " Spaced "]) do
          result = %{"title" => "Inception.2010.1080p-G#{n}", "downloadUrl" => "magnet:?#{n}"}
          if indexer == :absent, do: result, else: Map.put(result, "indexer", indexer)
        end
      )
    end)

    assert {:ok, results} = Prowlarr.search("tt1375666")

    assert Enum.map(results, &{&1.indexer_name, &1.indexer_source}) == [
             {nil, "prowlarr"},
             {"NZBgeek", "prowlarr"},
             {nil, "prowlarr"},
             {nil, "prowlarr"},
             {nil, "prowlarr"},
             {nil, "prowlarr"},
             {" Spaced ", "prowlarr"}
           ]
  end

  # #1632: Prowlarr asks no indexer whose caps lack `imdbid` (#1613), so the standard movie
  # search sends the id query alone and never the text.
  test "search_movie/3 sends search/1's IMDb id query and ignores the text and categories" do
    test_pid = self()

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      send(test_pid, {:prowlarr_params, conn.request_path, conn.params})
      Req.Test.json(conn, [%{"title" => "Dune.2021.1080p-GRP", "downloadUrl" => "magnet:?1"}])
    end)

    assert {:ok, [%{title: "Dune.2021.1080p-GRP"}]} =
             Prowlarr.search_movie("tt1160419", "Dune 2021", categories: [5070])

    assert_received {:prowlarr_params, "/api/v1/search",
                     %{"query" => "{ImdbId:tt1160419}", "type" => "movie"} = params}

    refute Map.has_key?(params, "categories")
    refute_received {:prowlarr_params, _path, _params}
  end

  # #1627: `moviesearch` is no Newznab function, Prowlarr sent it to the Newznab indexers it asked
  # as `t=moviesearch`, and on prod altHUB and NinjaCentral answered it with no results. Prowlarr
  # sends `search` as `t=search`, scoped here to the movie category.
  test "search_movie_query/2 sends a free-text search scoped to the movie category by default" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"

      assert conn.params == %{
               "query" => "Dune 2021",
               "type" => "search",
               "categories" => "2000"
             }

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_movie_query("Dune 2021", [])
  end

  test "search_movie_query/2 sends the caller's categories in place of the movie category and retains anime metadata" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params == %{
               "query" => "Kimi no Na wa 2016",
               "type" => "search",
               "categories" => "5070"
             }

      Req.Test.json(conn, [
        nil,
        %{"title" => nil, "downloadUrl" => "http://prowlarr:9696/bad"},
        %{
          "title" => "[Group] Kimi no Na wa (2016) [1080p]",
          "size" => 8_000_000_000,
          "downloadUrl" => "http://prowlarr:9696/movie/1",
          "protocol" => "torrent",
          "categories" => [%{"id" => 5070}, %{"id" => "not-an-integer"}],
          "indexerId" => 12,
          "publishDate" => "2026-07-13T10:00:00Z"
        }
      ])
    end)

    assert {:ok, [result]} =
             Prowlarr.search_movie_query("Kimi no Na wa 2016", categories: [5070])

    assert result.category_ids == [5070]
    assert result.indexer_id == 12
    assert result.published_at == ~U[2026-07-13 10:00:00Z]
  end

  test "search_movie_query/2 drops results whose title exceeds the length bound" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Req.Test.json(conn, [
        %{"title" => String.duplicate("A", 100_000), "downloadUrl" => "http://prowlarr:9696/x"},
        %{"title" => String.duplicate("A", 1025), "downloadUrl" => "http://prowlarr:9696/y"},
        %{"title" => String.duplicate("A", 1024), "downloadUrl" => "http://prowlarr:9696/z"}
      ])
    end)

    assert {:ok, [%{download_url: "http://prowlarr:9696/z"}]} =
             Prowlarr.search_movie_query("x", [])
  end

  test "search_tv_query/2 uses tvsearch and drops entries without a usable URL" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "ワンピース 1122"
      assert conn.params["type"] == "tvsearch"
      assert conn.params["categories"] == "5070"

      Req.Test.json(conn, [
        %{"title" => "No URL", "downloadUrl" => 42},
        %{
          "title" => "[Group] ワンピース - 1122 [1080p]",
          "size" => "unknown",
          "downloadUrl" => "   ",
          "magnetUrl" => "magnet:?xt=urn:btih:onepiece",
          "protocol" => %{"bad" => true},
          "categories" => "bad",
          "indexerId" => "bad",
          "publishDate" => "bad"
        }
      ])
    end)

    assert {:ok, [result]} = Prowlarr.search_tv_query("ワンピース 1122", categories: [5070])
    assert result.size == nil
    assert result.protocol == :torrent
    assert result.category_ids == []
    assert result.indexer_id == nil
    assert result.published_at == nil
  end

  test "search_tv/3 queries tvsearch by TVDB id + title + season and normalizes results" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["type"] == "tvsearch"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [
            %{
              "title" => "Breaking.Bad.S01E01.1080p.BluRay.x264-GRP",
              "size" => 2_000_000_000,
              "downloadUrl" => "http://prowlarr:9696/file/1",
              "seeders" => 30,
              "protocol" => "torrent",
              "tvdbId" => 1396
            }
          ])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, [result]} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert result == %{
             title: "Breaking.Bad.S01E01.1080p.BluRay.x264-GRP",
             size: 2_000_000_000,
             download_url: "http://prowlarr:9696/file/1",
             download_url_origin: "http://prowlarr:9696",
             protocol: :torrent,
             category_ids: [],
             indexer_id: nil,
             indexer_source: "prowlarr",
             indexer_name: nil,
             tvdb_id: 1396,
             published_at: nil,
             query_origins: [:id_scoped]
           }
  end

  test "search_tv/3 unions the id and title queries, deduped by download_url" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01.From.Id", "downloadUrl" => "http://prowlarr:9696/file/1"}
          ])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01.Duplicate", "downloadUrl" => "http://prowlarr:9696/file/1"},
            %{"title" => "BB.S01.Scraper.Only", "downloadUrl" => "http://prowlarr:9696/file/2"}
          ])
      end
    end)

    assert {:ok, results} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert Enum.map(results, &{&1.title, &1.query_origins}) == [
             {"BB.S01.From.Id", [:id_scoped, :free_text]},
             {"BB.S01.Scraper.Only", [:free_text]}
           ]
  end

  # #1515: a refused submission blocks its title per indexer, so one link from two indexers must
  # reach the scorer as two results, each with the query origins of every copy of the link.
  test "search_tv/3 merges one link only within one indexer" do
    magnet = "magnet:?xt=urn:btih:shared"

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [%{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 1}])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 1},
            %{"title" => "BB.S01.Other", "magnetUrl" => magnet, "indexerId" => 2, "size" => 5}
          ])
      end
    end)

    assert {:ok, [first, second]} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert {first.indexer_id, first.query_origins, second.indexer_id} ==
             {1, [:id_scoped, :free_text], 2}

    # Each indexer's result is the link's first copy under its own indexer id.
    assert Map.delete(second, :indexer_id) == Map.delete(first, :indexer_id)
  end

  # #1644: each indexer's result names its own indexer, and every result is a Prowlarr one.
  test "search_tv/3 gives each indexer's copy of one link its own indexer name" do
    magnet = "magnet:?xt=urn:btih:shared"

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 1, "indexer" => "One"}
          ])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 2, "indexer" => "Two"}
          ])
      end
    end)

    assert {:ok, results} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert Enum.map(results, &{&1.indexer_id, &1.indexer_name, &1.indexer_source}) == [
             {1, "One", "prowlarr"},
             {2, "Two", "prowlarr"}
           ]

    refute Enum.any?(results, &Map.has_key?(&1, :credentials_version))
  end

  test "search_tv/3 takes each indexer's name from its first copy of a link" do
    magnet = "magnet:?xt=urn:btih:shared"
    copy = &%{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => &1, "indexer" => &2}

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" -> Req.Test.json(conn, [copy.(1, "One"), copy.(2, "Two")])
        "Breaking Bad {Season:1}" -> Req.Test.json(conn, [copy.(2, "Two later")])
      end
    end)

    assert {:ok, results} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert Enum.map(results, &{&1.indexer_id, &1.indexer_name, &1.query_origins}) == [
             {1, "One", [:id_scoped, :free_text]},
             {2, "Two", [:id_scoped, :free_text]}
           ]
  end

  test "search_tv/3 gives a folded copy with no indexer id the named copy's indexer name" do
    magnet = "magnet:?xt=urn:btih:shared"

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01", "magnetUrl" => magnet, "indexer" => "Nameless"}
          ])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 7, "indexer" => "Seven"}
          ])
      end
    end)

    assert {:ok, results} = Prowlarr.search_tv(1396, "Breaking Bad", 1)
    assert Enum.map(results, &{&1.indexer_id, &1.indexer_name}) == [{7, "Seven"}]
  end

  test "search_tv/3 folds a copy with no indexer id into its link's copy that names one" do
    magnet = "magnet:?xt=urn:btih:shared"

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          Req.Test.json(conn, [%{"title" => "BB.S01", "magnetUrl" => magnet}])

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [%{"title" => "BB.S01", "magnetUrl" => magnet, "indexerId" => 7}])
      end
    end)

    assert {:ok, results} = Prowlarr.search_tv(1396, "Breaking Bad", 1)

    assert Enum.map(results, &{&1.indexer_id, &1.query_origins}) == [
             {7, [:id_scoped, :free_text]}
           ]
  end

  test "search_tv/3 keeps one side's results when the other query fails" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.params["query"] do
        "{TvdbId:1396}{Season:1}" ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})

        "Breaking Bad {Season:1}" ->
          Req.Test.json(conn, [
            %{"title" => "BB.S01.Scraper.Only", "downloadUrl" => "http://prowlarr:9696/file/2"}
          ])
      end
    end)

    assert {:ok, [%{title: "BB.S01.Scraper.Only", query_origins: [:free_text]}]} =
             Prowlarr.search_tv(1396, "Breaking Bad", 1)
  end

  test "search_tv/3 queries season 0 sanely (a Standard series' explicitly monitored specials)" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] in ["{TvdbId:1396}{Season:0}", "Breaking Bad {Season:0}"]
      assert conn.params["type"] == "tvsearch"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_tv(1396, "Breaking Bad", 0)
  end

  test "search_tv/3 falls back to a free-text season-0 query when tvdb_id is nil" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "Breaking Bad {Season:0}"
      assert conn.params["type"] == "tvsearch"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Prowlarr.search_tv(nil, "Breaking Bad", 0)
  end

  test "search_tv/3 tags a nil-TVDB title query as free text" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.params["query"] == "Breaking Bad {Season:2}"
      assert conn.params["type"] == "tvsearch"

      Req.Test.json(conn, [
        %{"title" => "Breaking.Bad.S02E01", "downloadUrl" => "http://prowlarr:9696/file/2"}
      ])
    end)

    assert {:ok, [%{query_origins: [:free_text]}]} =
             Prowlarr.search_tv(nil, "Breaking Bad", 2)
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

  describe "fetch_download/3" do
    # The options a client builds, with the test seams `Cinder.Download.Client.Fetch` reads.
    defp fetch_opts(extra \\ []) do
      [
        max_bytes: 1024,
        error_tag: :torrent_fetch_status,
        allow_magnet: true,
        plug: {Req.Test, Cinder.ProwlarrFetchStub},
        resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ] ++ extra
    end

    defp stub_fetch(fun) do
      test_pid = self()

      Req.Test.stub(Cinder.ProwlarrFetchStub, fn conn ->
        send(test_pid, {:fetched, conn.host, conn.request_path})
        fun.(conn)
      end)
    end

    test "answers the link's bytes, fetched from the link itself" do
      torrent = TorrentFixture.minimal()
      stub_fetch(&Plug.Conn.send_resp(&1, 200, torrent))

      assert {:ok, ^torrent} =
               Prowlarr.fetch_download(
                 "https://indexer.example/dl/1.torrent",
                 "https://indexer.example",
                 fetch_opts()
               )

      assert_received {:fetched, "indexer.example", "/dl/1.torrent"}
    end

    test "answers a magnet redirect and a fetch error as Fetch.bytes/3 does" do
      stub_fetch(fn
        %{request_path: "/magnet"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "magnet:?xt=urn:btih:abc")
          |> Plug.Conn.send_resp(302, "")

        conn ->
          Plug.Conn.send_resp(conn, 503, "")
      end)

      origin = "https://indexer.example"

      assert {:magnet, "magnet:?xt=urn:btih:abc"} =
               Prowlarr.fetch_download("#{origin}/magnet", origin, fetch_opts())

      assert {:error, {:torrent_fetch_status, 503}} =
               Prowlarr.fetch_download("#{origin}/gone", origin, fetch_opts())
    end

    # `Cinder.Download` adds the intent's provenance to the options; `Fetch` reads none of it.
    test "fetches the same way with the provenance keys in the options" do
      nzb = NzbFixture.minimal()
      stub_fetch(&Plug.Conn.send_resp(&1, 200, nzb))

      opts = fetch_opts(indexer_source: "prowlarr", indexer_id: 7, credentials_version: 2)

      assert {:ok, ^nzb} =
               Prowlarr.fetch_download(
                 "https://indexer.example/dl/2",
                 "https://indexer.example",
                 opts
               )

      assert_received {:fetched, "indexer.example", "/dl/2"}
    end
  end
end
