defmodule Cinder.Catalog.TMDB.HTTPTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.TMDB.HTTP

  test "search/1 normalizes TMDB results, tolerating missing year/poster" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/movie"
      assert conn.params["query"] == "inception"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 27_205,
            "title" => "Inception",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg"
          },
          %{"id" => 1, "title" => "Obscure", "release_date" => "", "poster_path" => nil}
        ]
      })
    end)

    assert {:ok, results} = HTTP.search("inception")

    # Search bodies omit genres/runtime (details-only), so those come back [] / nil; the
    # descriptive fields /search/movie does send (overview/vote_average/release_date) pass through.
    assert results == [
             %{
               tmdb_id: 27_205,
               title: "Inception",
               year: 2010,
               poster_path: "/p.jpg",
               imdb_id: nil,
               original_language: nil,
               overview: nil,
               runtime: nil,
               genres: [],
               vote_average: nil,
               release_date: ~D[2010-07-16]
             },
             %{
               tmdb_id: 1,
               title: "Obscure",
               year: nil,
               poster_path: nil,
               imdb_id: nil,
               original_language: nil,
               overview: nil,
               runtime: nil,
               genres: [],
               vote_average: nil,
               release_date: nil
             }
           ]
  end

  test "search/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"status_message" => "no"})
    end)

    assert {:error, _} = HTTP.search("inception")
  end

  test "search/1 returns an error (not a raise) on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false, "status_message" => "bad"})
    end)

    assert {:error, :unexpected_response} = HTTP.search("inception")
  end

  test "get_movie/1 returns an error on a 200 that isn't a movie body" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false, "status_message" => "not found"})
    end)

    assert {:error, :unexpected_response} = HTTP.get_movie(0)
  end

  test "get_movie/1 normalizes a single (unwrapped) movie body" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205"

      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16",
        "poster_path" => "/p.jpg",
        "imdb_id" => "tt1375666",
        "original_language" => "fr"
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 27_205,
              title: "Inception",
              year: 2010,
              poster_path: "/p.jpg",
              imdb_id: "tt1375666",
              original_language: "fr"
            }} = HTTP.get_movie(27_205)
  end

  test "search_tv/1 normalizes results (name->title, first_air_date->year)" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/tv"
      assert conn.params["query"] == "breaking"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 1396,
            "name" => "Breaking Bad",
            "first_air_date" => "2008-01-20",
            "poster_path" => "/bb.jpg"
          },
          %{"id" => 2, "name" => "TBA", "first_air_date" => "", "poster_path" => nil}
        ]
      })
    end)

    assert {:ok,
            [
              %{tmdb_id: 1396, title: "Breaking Bad", year: 2008, poster_path: "/bb.jpg"},
              %{tmdb_id: 2, title: "TBA", year: nil, poster_path: nil}
            ]} = HTTP.search_tv("breaking")
  end

  test "get_series/1 pulls tvdb_id from external_ids and lists season numbers" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1396"
      assert conn.params["append_to_response"] == "external_ids"

      Req.Test.json(conn, %{
        "id" => 1396,
        "name" => "Breaking Bad",
        "first_air_date" => "2008-01-20",
        "poster_path" => "/bb.jpg",
        "original_language" => "fr",
        "external_ids" => %{"tvdb_id" => 81_189, "imdb_id" => "tt0903747"},
        "seasons" => [%{"season_number" => 0}, %{"season_number" => 1}]
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 1396,
              tvdb_id: 81_189,
              title: "Breaking Bad",
              year: 2008,
              poster_path: "/bb.jpg",
              original_language: "fr",
              seasons: [%{season_number: 0}, %{season_number: 1}]
            }} = HTTP.get_series(1396)
  end

  test "get_series/1 tolerates a missing external_ids block" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{
        "id" => 7,
        "name" => "No IDs",
        "first_air_date" => "2020-01-01",
        "seasons" => []
      })
    end)

    assert {:ok, %{tmdb_id: 7, tvdb_id: nil, seasons: []}} = HTTP.get_series(7)
  end

  test "get_season/2 normalizes episodes and maps an empty air_date to nil" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1396/season/1"

      Req.Test.json(conn, %{
        "season_number" => 1,
        "episodes" => [
          %{"id" => 62_085, "episode_number" => 1, "name" => "Pilot", "air_date" => "2008-01-20"},
          %{"id" => 62_086, "episode_number" => 2, "name" => "TBA", "air_date" => ""}
        ]
      })
    end)

    assert {:ok,
            %{
              season_number: 1,
              episodes: [
                %{
                  tmdb_episode_id: 62_085,
                  episode_number: 1,
                  title: "Pilot",
                  air_date: ~D[2008-01-20]
                },
                %{tmdb_episode_id: 62_086, episode_number: 2, title: "TBA", air_date: nil}
              ]
            }} = HTTP.get_season(1396, 1)
  end

  test "normalizes movie and TV alternative titles" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      case conn.request_path do
        "/3/movie/372058/alternative_titles" ->
          Req.Test.json(conn, %{
            "titles" => [
              %{"title" => "Kimi no Na wa.", "iso_3166_1" => "JP", "type" => ""}
            ]
          })

        "/3/tv/37854/alternative_titles" ->
          Req.Test.json(conn, %{
            "results" => [
              %{"title" => "Pocket Monsters", "iso_3166_1" => "US", "type" => "working"}
            ]
          })
      end
    end)

    assert {:ok, [%{title: "Kimi no Na wa.", country_code: "JP", kind: :alternative}]} =
             HTTP.get_movie_alternative_titles(372_058)

    assert {:ok, [%{title: "Pocket Monsters", country_code: "US", kind: :alternative}]} =
             HTTP.get_series_alternative_titles(37_854)
  end

  test "normalizes and orders an episode group" do
    Req.Test.expect(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/37854/episode_groups"

      Req.Test.json(conn, %{
        "results" => [%{"id" => "absolute-id", "type" => 2, "name" => "Absolute"}]
      })
    end)

    assert {:ok, [%{id: "absolute-id", type: 2, name: "Absolute"}]} =
             HTTP.get_episode_groups(37_854)

    Req.Test.expect(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/episode_group/absolute-id"

      Req.Test.json(conn, %{
        "id" => "absolute-id",
        "type" => 2,
        "name" => "Absolute",
        "groups" => [
          %{
            "order" => 1,
            "episodes" => [
              %{
                "id" => 12_347,
                "order" => 0,
                "season_number" => 1,
                "episode_number" => 3,
                "name" => "Ignored"
              }
            ]
          },
          %{
            "order" => 0,
            "episodes" => [
              %{"id" => 12_346, "order" => 1, "season_number" => 1, "episode_number" => 2},
              %{"id" => 12_345, "order" => 0, "season_number" => 1, "episode_number" => 1}
            ]
          }
        ]
      })
    end)

    assert {:ok,
            %{
              id: "absolute-id",
              type: 2,
              name: "Absolute",
              entries: [
                %{
                  tmdb_episode_id: 12_345,
                  group_order: 0,
                  order: 0,
                  season_number: 1,
                  episode_number: 1
                },
                %{
                  tmdb_episode_id: 12_346,
                  group_order: 0,
                  order: 1,
                  season_number: 1,
                  episode_number: 2
                },
                %{
                  tmdb_episode_id: 12_347,
                  group_order: 1,
                  order: 0,
                  season_number: 1,
                  episode_number: 3
                }
              ]
            }} = HTTP.get_episode_group("absolute-id")
  end

  test "alternative titles reject container-valued retained fields" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      key = if String.starts_with?(conn.request_path, "/3/movie/"), do: "titles", else: "results"
      Req.Test.json(conn, %{key => [%{"title" => ["not", "a", "title"], "iso_3166_1" => "JP"}]})
    end)

    assert {:error, :unexpected_response} = HTTP.get_movie_alternative_titles(372_058)
    assert {:error, :unexpected_response} = HTTP.get_series_alternative_titles(37_854)
  end

  test "episode groups reject malformed retained fields" do
    Req.Test.expect(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{
        "results" => [%{"id" => 123, "type" => 2, "name" => "Absolute"}]
      })
    end)

    assert {:error, :unexpected_response} = HTTP.get_episode_groups(37_854)

    Req.Test.expect(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{
        "id" => "absolute-id",
        "type" => 2,
        "name" => "Absolute",
        "groups" => [
          %{
            "order" => 0,
            "episodes" => [
              %{"id" => 12_345, "order" => "0", "season_number" => 1, "episode_number" => 1}
            ]
          }
        ]
      })
    end)

    assert {:error, :unexpected_response} = HTTP.get_episode_group("absolute-id")
  end

  test "search/1 does not forward bearer credentials across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.TMDBStub, fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "authorization")})
          Req.Test.json(conn, %{"results" => []})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/search")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:tmdb_status, ^status}} = HTTP.search("inception")
      refute_received {:attacker_called, _}
    end
  end

  test "search/1 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = HTTP.search("inception")
  end
end
