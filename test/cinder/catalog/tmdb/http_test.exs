defmodule Cinder.Catalog.TMDB.HTTPTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.TMDB.HTTP

  test "search/2 sends the requested locale and normalizes TMDB results" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/movie"
      assert conn.params["query"] == "inception"
      assert conn.params["language"] == "fr-FR"

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

    assert {:ok, results} = HTTP.search("inception", "fr")

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

  test "search/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"status_message" => "no"})
    end)

    assert {:error, _} = HTTP.search("inception", "en")
  end

  test "search/2 returns an error (not a raise) on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false, "status_message" => "bad"})
    end)

    assert {:error, :unexpected_response} = HTTP.search("inception", "en")
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
      refute Map.has_key?(conn.params, "language")

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

  test "search_tv/2 sends the requested locale and normalizes results" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/tv"
      assert conn.params["query"] == "breaking"
      assert conn.params["language"] == "fr-FR"

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
            ]} = HTTP.search_tv("breaking", "fr")
  end

  test "get_series/1 pulls tvdb_id from external_ids and lists season numbers" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1396"
      assert conn.params["append_to_response"] == "external_ids,translations"
      refute Map.has_key?(conn.params, "language")

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

  test "get_series/1 parses translated titles from data.name" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1396"
      assert conn.params["append_to_response"] == "external_ids,translations"

      Req.Test.json(conn, %{
        "id" => 1396,
        "name" => "Breaking Bad",
        "first_air_date" => "2008-01-20",
        "poster_path" => "/bb.jpg",
        "original_language" => "en",
        "external_ids" => %{"tvdb_id" => 81_189},
        "seasons" => [%{"season_number" => 1}],
        "translations" => %{
          "translations" => [
            %{
              "iso_639_1" => "fr",
              "data" => %{
                "name" => "Breaking Bad",
                "overview" => "Un professeur de chimie.",
                "homepage" => ""
              }
            }
          ]
        }
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 1396,
              title: "Breaking Bad",
              localizations: %{
                "fr" => %{
                  "title" => "Breaking Bad",
                  "overview" => "Un professeur de chimie."
                }
              }
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

  test "get_movie/1 stays canonical, prefers the locale region, and trims translations" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205"
      assert conn.params["append_to_response"] == "translations"
      refute Map.has_key?(conn.params, "language")

      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16",
        "poster_path" => "/p.jpg",
        "imdb_id" => "tt1375666",
        "original_language" => "en",
        "translations" => %{
          "translations" => [
            %{
              "iso_639_1" => "fr",
              "iso_3166_1" => "CA",
              "data" => %{"title" => "Chantez !", "overview" => "Version canadienne."}
            },
            %{
              "iso_639_1" => "fr",
              "iso_3166_1" => "FR",
              "data" => %{"title" => "Tous en scène", "overview" => "Version française."}
            },
            %{
              "iso_639_1" => "es",
              "iso_3166_1" => "ES",
              "data" => %{"title" => "El origen", "overview" => "Un ladrón.", "homepage" => ""}
            }
          ]
        }
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 27_205,
              title: "Inception",
              localizations: %{
                "fr" => %{
                  "title" => "Tous en scène",
                  "overview" => "Version française."
                }
              }
            }} = HTTP.get_movie(27_205)
  end

  test "get_movie/1 coalesces translation fields independently across regions" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      translations =
        case conn.request_path do
          "/3/movie/1" ->
            [
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "FR",
                "data" => %{"title" => "", "overview" => "Résumé français."}
              },
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "CA",
                "data" => %{"title" => "Titre québécois", "overview" => ""}
              }
            ]

          "/3/movie/2" ->
            [
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "FR",
                "data" => %{"title" => "Titre français", "overview" => nil}
              },
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "CA",
                "data" => %{"title" => nil, "overview" => "Résumé québécois."}
              }
            ]
        end

      Req.Test.json(conn, %{
        "id" => conn.request_path |> String.split("/") |> List.last() |> String.to_integer(),
        "title" => "Canonical",
        "translations" => %{"translations" => translations}
      })
    end)

    assert {:ok,
            %{
              localizations: %{
                "fr" => %{
                  "title" => "Titre québécois",
                  "overview" => "Résumé français."
                }
              }
            }} = HTTP.get_movie(1)

    assert {:ok,
            %{
              localizations: %{
                "fr" => %{
                  "title" => "Titre français",
                  "overview" => "Résumé québécois."
                }
              }
            }} = HTTP.get_movie(2)
  end

  test "get_movie/1 keeps a locale when only one field resolves across all variants" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      translations =
        case conn.request_path do
          # title resolves nowhere; overview only on fr-CA
          "/3/movie/3" ->
            [
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "CA",
                "data" => %{"title" => "", "overview" => "Résumé seul."}
              }
            ]

          # overview resolves nowhere; title only on fr-FR
          "/3/movie/4" ->
            [
              %{
                "iso_639_1" => "fr",
                "iso_3166_1" => "FR",
                "data" => %{"title" => "Titre seul", "overview" => ""}
              }
            ]
        end

      Req.Test.json(conn, %{
        "id" => conn.request_path |> String.split("/") |> List.last() |> String.to_integer(),
        "title" => "Canonical",
        "translations" => %{"translations" => translations}
      })
    end)

    assert {:ok, %{localizations: %{"fr" => %{"overview" => "Résumé seul."} = entry}}} =
             HTTP.get_movie(3)

    assert entry["title"] in [nil, ""]

    assert {:ok, %{localizations: %{"fr" => %{"title" => "Titre seul"}}}} = HTTP.get_movie(4)
  end

  test "get_season/3 sends the requested locale and normalizes episodes" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1396/season/1"
      assert conn.params["language"] == "fr-FR"

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
            }} = HTTP.get_season(1396, 1, "fr")
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
        "results" => [
          %{
            "id" => "absolute-id",
            "type" => 2,
            "name" => "Absolute",
            "group_count" => 3,
            "episode_count" => 63
          }
        ]
      })
    end)

    assert {:ok,
            [
              %{
                id: "absolute-id",
                type: 2,
                name: "Absolute",
                group_count: 3,
                episode_count: 63
              }
            ]} = HTTP.get_episode_groups(37_854)

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

  test "search/2 does not forward bearer credentials across redirects" do
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

      assert {:error, {:tmdb_status, ^status}} = HTTP.search("inception", "en")
      refute_received {:attacker_called, _}
    end
  end

  test "search/2 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = HTTP.search("inception", "en")
  end
end
