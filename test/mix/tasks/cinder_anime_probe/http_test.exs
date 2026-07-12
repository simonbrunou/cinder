defmodule Mix.Tasks.Cinder.Anime.Probe.HTTPTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinder.Anime.Probe.HTTP

  @tmdb_stub __MODULE__.TMDBStub
  @prowlarr_stub __MODULE__.ProwlarrStub

  @title %{
    slug: "one-piece",
    kind: :tv,
    tmdb_id: 37_854,
    discovery_queries: ["One Piece"],
    prowlarr_queries: ["One Piece"],
    expect: %{required_group_types: [2]}
  }

  test "fetches and allowlists the TV provider observations" do
    Req.Test.stub(@tmdb_stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tmdb-token"]

      case conn.request_path do
        "/3/search/tv" ->
          assert conn.params["query"] == "One Piece"

          Req.Test.json(conn, %{
            "results" => [
              %{"id" => 37_854, "name" => "One Piece", "overview" => "not retained"}
            ]
          })

        "/3/tv/37854/alternative_titles" ->
          Req.Test.json(conn, %{
            "results" => [%{"iso_3166_1" => "JP", "title" => "ワンピース"}],
            "secret" => "not retained"
          })

        "/3/tv/37854" ->
          Req.Test.json(conn, %{
            "id" => 37_854,
            "name" => "One Piece",
            "seasons" => [%{"season_number" => 0}, %{"season_number" => 1}],
            "overview" => "not retained"
          })

        "/3/tv/37854/episode_groups" ->
          Req.Test.json(conn, %{
            "results" => [
              %{"id" => "absolute-group", "type" => 2, "name" => "Absolute Order"},
              %{"id" => "ignored-group", "type" => 1, "name" => "Original Air Date"}
            ]
          })

        "/3/tv/episode_group/absolute-group" ->
          Req.Test.json(conn, %{
            "id" => "absolute-group",
            "type" => 2,
            "name" => "Absolute Order",
            "groups" => [
              %{
                "order" => 0,
                "episodes" => [
                  %{
                    "id" => 12_345,
                    "order" => 0,
                    "season_number" => 1,
                    "episode_number" => 1,
                    "name" => "not retained"
                  }
                ]
              }
            ]
          })

        path ->
          flunk("unexpected TMDB request: #{path}")
      end
    end)

    Req.Test.stub(@prowlarr_stub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["query"] == "One Piece"
      assert conn.params["type"] == "tvsearch"
      assert conn.params["categories"] in [nil, "5070"]
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["prowlarr-key"]

      release =
        %{
          release_fixture()
          | "categories" => [
              %{"id" => 5070, "name" => "TV/Anime"},
              %{"id" => 105_070, "name" => nil}
            ]
        }

      Req.Test.json(conn, [release])
    end)

    assert {:ok, observation} = HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

    assert observation.searches == [
             %{query: "One Piece", results: [%{id: 37_854, title: "One Piece"}]}
           ]

    assert observation.alternatives == [%{title: "ワンピース"}]

    assert observation.details == %{
             id: 37_854,
             title: "One Piece",
             seasons: [%{season_number: 0}, %{season_number: 1}]
           }

    assert [absolute_group] = observation.groups

    assert absolute_group == %{
             id: "absolute-group",
             type: 2,
             name: "Absolute Order",
             entries: [
               %{
                 episode_id: 12_345,
                 group_order: 0,
                 order: 0,
                 season_number: 1,
                 episode_number: 1
               }
             ]
           }

    assert [all, anime] = observation.prowlarr
    assert %{query: "One Piece", mode: :all, results: [release]} = all
    assert %{query: "One Piece", mode: :anime, results: [^release]} = anime

    assert release == %{
             title: "[SubsPlease] One Piece - 1122 (1080p) [ABCDEF01]",
             size: 1_400_000_000,
             protocol: "torrent",
             categories: [%{id: 5070, name: "TV/Anime"}, %{id: 105_070, name: nil}],
             published_at: "2026-07-01T12:00:00Z",
             has_indexer_identity: true
           }
  end

  test "derives indexer identity availability without retaining identity values" do
    stub_tmdb_success()

    releases = [
      %{release_fixture() | "indexer" => "named-indexer", "indexerId" => nil},
      %{release_fixture() | "indexer" => nil, "indexerId" => 42},
      %{release_fixture() | "indexer" => %{"token" => "remote-secret"}, "indexerId" => "42"}
    ]

    Req.Test.stub(@prowlarr_stub, fn conn -> Req.Test.json(conn, releases) end)

    assert {:ok, %{prowlarr: [%{results: normalized} | _]}} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

    assert Enum.map(normalized, & &1.has_indexer_identity) == [true, true, false]

    refute inspect(normalized) =~ "named-indexer"
    refute inspect(normalized) =~ "remote-secret"
    refute inspect(normalized) =~ "indexerId"
    refute inspect(normalized) =~ "indexer:"
  end

  test "uses the matching movie routes and skips episode groups" do
    title = %{@title | kind: :movie, tmdb_id: 372_058, expect: %{required_group_types: []}}

    Req.Test.stub(@tmdb_stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tmdb-token"]

      case conn.request_path do
        "/3/search/movie" ->
          assert conn.params["query"] == "One Piece"
          Req.Test.json(conn, %{"results" => [%{"id" => 372_058, "title" => "Your Name."}]})

        "/3/movie/372058/alternative_titles" ->
          Req.Test.json(conn, %{"titles" => [%{"title" => "Kimi no Na wa."}]})

        "/3/movie/372058" ->
          Req.Test.json(conn, %{"id" => 372_058, "title" => "Your Name."})

        path ->
          flunk("unexpected TMDB request: #{path}")
      end
    end)

    Req.Test.stub(@prowlarr_stub, fn conn ->
      assert conn.params["type"] == "moviesearch"
      Req.Test.json(conn, [])
    end)

    assert {:ok, observation} = HTTP.fetch_title(title, tmdb_config(), prowlarr_config())
    assert observation.groups == []
    assert observation.alternatives == [%{title: "Kimi no Na wa."}]
  end

  test "normalizes at most 50 Prowlarr results per request" do
    stub_tmdb_success()

    Req.Test.stub(@prowlarr_stub, fn conn ->
      results = for index <- 1..51, do: %{release_fixture() | "title" => "release-#{index}"}
      Req.Test.json(conn, results)
    end)

    assert {:ok, %{prowlarr: searches}} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

    assert Enum.all?(searches, &(length(&1.results) == 50))
  end

  test "returns a sanitized tagged TMDB status error" do
    Req.Test.stub(@tmdb_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"token" => "tmdb-token", "body" => "raw-secret"})
    end)

    assert {:error, {:tmdb_status, 401}} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())
  end

  test "returns a sanitized tagged Prowlarr status error" do
    stub_tmdb_success()

    Req.Test.stub(@prowlarr_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"api_key" => "prowlarr-key", "body" => "raw-secret"})
    end)

    assert {:error, {:prowlarr_status, 503}} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())
  end

  test "rejects an oversized response with a sanitized atom" do
    Req.Test.stub(@tmdb_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"secret":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())
  end

  test "does not follow TMDB redirects or expose its bearer token" do
    parent = self()

    Req.Test.stub(@tmdb_stub, fn conn ->
      if conn.host == "attacker.test" do
        send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"secret" => "raw-body"})
      else
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.test/steal")
        |> Plug.Conn.send_resp(302, "raw-body")
      end
    end)

    assert {:error, {:tmdb_status, 302}} =
             HTTP.fetch_title(@title, tmdb_config(redirect: true), prowlarr_config())

    refute_received {:attacker_called, _}
  end

  test "does not follow Prowlarr redirects or expose its API key" do
    parent = self()
    stub_tmdb_success()

    Req.Test.stub(@prowlarr_stub, fn conn ->
      if conn.host == "attacker.test" do
        send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "x-api-key")})
        Req.Test.json(conn, [])
      else
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.test/steal")
        |> Plug.Conn.send_resp(307, "raw-body")
      end
    end)

    assert {:error, {:prowlarr_status, 307}} =
             HTTP.fetch_title(@title, tmdb_config(), prowlarr_config(redirect: true))

    refute_received {:attacker_called, _}
  end

  test "forces GET and request bounds after merging hostile req_options" do
    parent = self()

    capture_options = fn request ->
      Req.Request.append_request_steps(request,
        capture_probe_options: fn request ->
          send(
            parent,
            {:probe_options, request.method, request.options[:receive_timeout],
             request.options[:connect_options]}
          )

          request
        end
      )
    end

    Req.Test.stub(@tmdb_stub, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/3/search/tv" -> Req.Test.json(conn, %{"results" => []})
        "/3/tv/37854/alternative_titles" -> Req.Test.json(conn, %{"results" => []})
        "/3/tv/37854" -> Req.Test.json(conn, %{"id" => 37_854, "name" => "One Piece"})
        "/3/tv/37854/episode_groups" -> Req.Test.json(conn, %{"results" => []})
      end
    end)

    Req.Test.stub(@prowlarr_stub, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    hostile_options = [
      method: :post,
      receive_timeout: 1,
      connect_options: [timeout: 1],
      redirect: true,
      plugins: [capture_options]
    ]

    assert {:ok, _observation} =
             HTTP.fetch_title(
               @title,
               tmdb_config(hostile_options),
               prowlarr_config(hostile_options)
             )

    for _request <- 1..6 do
      assert_receive {:probe_options, :get, 15_000, [timeout: 15_000]}
    end
  end

  test "rejects malformed TMDB list elements with a sanitized error" do
    malformed_responses = [
      %{"/3/search/tv" => %{"results" => ["remote-secret"]}},
      %{"/3/tv/37854/alternative_titles" => %{"results" => ["remote-secret"]}},
      %{
        "/3/tv/37854" => %{"id" => 37_854, "name" => "One Piece", "seasons" => ["remote-secret"]}
      },
      %{"/3/tv/37854/episode_groups" => %{"results" => ["remote-secret"]}},
      %{
        "/3/tv/37854/episode_groups" => %{
          "results" => [%{"id" => "absolute-group", "type" => 2, "name" => "Absolute"}]
        },
        "/3/tv/episode_group/absolute-group" => %{
          "id" => "absolute-group",
          "type" => 2,
          "name" => "Absolute",
          "groups" => [%{"order" => 0, "episodes" => ["remote-secret"]}]
        }
      }
    ]

    for overrides <- malformed_responses do
      stub_tmdb_responses(overrides)
      Req.Test.stub(@prowlarr_stub, fn conn -> Req.Test.json(conn, []) end)

      result = HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

      assert result == {:error, :unexpected_response}
      refute inspect(result) =~ "remote-secret"
    end
  end

  test "rejects malformed TMDB retained scalars with exactly the sanitized error" do
    secret = %{"token" => "remote-secret"}

    malformed_responses = [
      %{"/3/search/tv" => %{"results" => [%{"id" => secret, "name" => "One Piece"}]}},
      %{"/3/search/tv" => %{"results" => [%{"id" => 37_854, "name" => nil}]}},
      %{"/3/search/tv" => %{"results" => [%{"id" => 37_854, "name" => "  "}]}},
      %{
        "/3/search/tv" => %{
          "results" => [%{"id" => 37_854, "name" => String.duplicate("x", 4_097)}]
        }
      },
      %{"/3/tv/37854/alternative_titles" => %{"results" => [%{"title" => secret}]}},
      %{"/3/tv/37854" => %{"id" => nil, "name" => "One Piece", "seasons" => []}},
      %{"/3/tv/37854" => %{"id" => 37_854, "name" => secret, "seasons" => []}},
      %{
        "/3/tv/37854" => %{
          "id" => 37_854,
          "name" => "One Piece",
          "seasons" => [%{"season_number" => secret}]
        }
      },
      %{
        "/3/tv/37854/episode_groups" => %{
          "results" => [%{"id" => secret, "type" => 2, "name" => "Absolute"}]
        }
      },
      %{
        "/3/tv/37854/episode_groups" => %{
          "results" => [%{"id" => "absolute-group", "type" => secret, "name" => "Absolute"}]
        }
      },
      %{
        "/3/tv/37854/episode_groups" => %{
          "results" => [%{"id" => "absolute-group", "type" => 2, "name" => secret}]
        }
      },
      group_detail_override(%{"id" => secret}),
      group_detail_override(%{"type" => secret}),
      group_detail_override(%{"name" => secret}),
      group_detail_override(%{"groups" => [%{"order" => secret, "episodes" => [episode()]}]}),
      group_detail_override(%{
        "groups" => [%{"order" => 0, "episodes" => [%{episode() | "id" => nil}]}]
      }),
      group_detail_override(%{
        "groups" => [%{"order" => 0, "episodes" => [%{episode() | "order" => secret}]}]
      }),
      group_detail_override(%{
        "groups" => [%{"order" => 0, "episodes" => [%{episode() | "season_number" => secret}]}]
      }),
      group_detail_override(%{
        "groups" => [%{"order" => 0, "episodes" => [%{episode() | "episode_number" => secret}]}]
      })
    ]

    for overrides <- malformed_responses do
      stub_tmdb_responses(overrides)
      Req.Test.stub(@prowlarr_stub, fn conn -> Req.Test.json(conn, []) end)

      result = HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

      assert result == {:error, :unexpected_response}
      refute inspect(result) =~ "remote-secret"
    end
  end

  test "rejects malformed Prowlarr results and categories with a sanitized error" do
    for payload <- [
          ["remote-secret"],
          [%{release_fixture() | "categories" => ["remote-secret"]}]
        ] do
      stub_tmdb_success()
      Req.Test.stub(@prowlarr_stub, fn conn -> Req.Test.json(conn, payload) end)

      result = HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

      assert result == {:error, :unexpected_response}
      refute inspect(result) =~ "remote-secret"
    end
  end

  test "rejects malformed Prowlarr retained scalars with exactly the sanitized error" do
    secret = %{"api_key" => "remote-secret"}

    malformed_releases = [
      %{release_fixture() | "title" => nil},
      %{release_fixture() | "title" => secret},
      %{release_fixture() | "size" => -1},
      %{release_fixture() | "size" => secret},
      %{release_fixture() | "protocol" => secret},
      %{release_fixture() | "protocol" => " \n "},
      %{release_fixture() | "protocol" => String.duplicate("x", 4_097)},
      %{release_fixture() | "categories" => [%{"id" => secret, "name" => "TV/Anime"}]},
      %{release_fixture() | "categories" => [%{"id" => 5070, "name" => ""}]},
      %{release_fixture() | "categories" => [%{"id" => 5070, "name" => " \n "}]},
      %{release_fixture() | "categories" => [%{"id" => 5070, "name" => ["remote-secret"]}]},
      %{release_fixture() | "categories" => [%{"id" => 5070, "name" => secret}]},
      %{release_fixture() | "publishDate" => nil},
      %{release_fixture() | "publishDate" => "not-a-timestamp"},
      %{release_fixture() | "publishDate" => secret}
    ]

    for release <- malformed_releases do
      stub_tmdb_success()
      Req.Test.stub(@prowlarr_stub, fn conn -> Req.Test.json(conn, [release]) end)

      result = HTTP.fetch_title(@title, tmdb_config(), prowlarr_config())

      assert result == {:error, :unexpected_response}
      refute inspect(result) =~ "remote-secret"
    end
  end

  defp stub_tmdb_success do
    Req.Test.stub(@tmdb_stub, fn conn ->
      case conn.request_path do
        "/3/search/tv" -> Req.Test.json(conn, %{"results" => []})
        "/3/tv/37854/alternative_titles" -> Req.Test.json(conn, %{"results" => []})
        "/3/tv/37854" -> Req.Test.json(conn, %{"id" => 37_854, "name" => "One Piece"})
        "/3/tv/37854/episode_groups" -> Req.Test.json(conn, %{"results" => []})
      end
    end)
  end

  defp stub_tmdb_responses(overrides) do
    responses =
      Map.merge(
        %{
          "/3/search/tv" => %{"results" => []},
          "/3/tv/37854/alternative_titles" => %{"results" => []},
          "/3/tv/37854" => %{
            "id" => 37_854,
            "name" => "One Piece",
            "seasons" => []
          },
          "/3/tv/37854/episode_groups" => %{"results" => []}
        },
        overrides
      )

    Req.Test.stub(@tmdb_stub, fn conn ->
      Req.Test.json(conn, Map.fetch!(responses, conn.request_path))
    end)
  end

  defp group_detail_override(detail_overrides) do
    %{
      "/3/tv/37854/episode_groups" => %{
        "results" => [%{"id" => "absolute-group", "type" => 2, "name" => "Absolute"}]
      },
      "/3/tv/episode_group/absolute-group" =>
        Map.merge(
          %{
            "id" => "absolute-group",
            "type" => 2,
            "name" => "Absolute",
            "groups" => [%{"order" => 0, "episodes" => [episode()]}]
          },
          detail_overrides
        )
    }
  end

  defp episode do
    %{
      "id" => 12_345,
      "order" => 0,
      "season_number" => 1,
      "episode_number" => 1
    }
  end

  defp tmdb_config(req_options \\ []) do
    [
      base_url: "https://tmdb.test",
      token: "tmdb-token",
      req_options: [plug: {Req.Test, @tmdb_stub}, retry: false] ++ req_options
    ]
  end

  defp prowlarr_config(req_options \\ []) do
    [
      base_url: "https://prowlarr.test",
      api_key: "prowlarr-key",
      req_options: [plug: {Req.Test, @prowlarr_stub}, retry: false] ++ req_options
    ]
  end

  defp release_fixture do
    %{
      "title" => "[SubsPlease] One Piece - 1122 (1080p) [ABCDEF01]",
      "size" => 1_400_000_000,
      "protocol" => "torrent",
      "categories" => [%{"id" => 5070, "name" => "TV/Anime"}],
      "publishDate" => "2026-07-01T12:00:00Z",
      "downloadUrl" => "https://prowlarr.test/download/secret",
      "magnetUrl" => "magnet:?xt=urn:btih:secret",
      "indexerId" => 99,
      "indexer" => "secret-indexer"
    }
  end
end
