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

  test "get_movie/1 appends credits + carries top-billed cast and the collection link" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205"
      assert conn.params["append_to_response"] == "translations,credits"

      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16",
        "belongs_to_collection" => %{
          "id" => 8945,
          "name" => "The Dark Knight Collection",
          "poster_path" => "/c.jpg"
        },
        "credits" => %{
          "cast" => [
            %{
              "id" => 2,
              "name" => "Second",
              "character" => "B",
              "order" => 1,
              "profile_path" => "/2.jpg"
            },
            %{
              "id" => 1,
              "name" => "First",
              "character" => "A",
              "order" => 0,
              "profile_path" => nil
            },
            # Malformed (no id) — dropped rather than crashing the strip.
            %{"name" => "Nameless", "order" => 2}
          ],
          "crew" => [%{"id" => 9, "name" => "Director", "job" => "Director"}]
        }
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 27_205,
              collection: %{tmdb_id: 8945, title: "The Dark Knight Collection"},
              cast: [
                %{tmdb_id: 1, name: "First", character: "A", profile_path: nil},
                %{tmdb_id: 2, name: "Second", character: "B", profile_path: "/2.jpg"}
              ]
            }} = HTTP.get_movie(27_205)
  end

  test "get_movie/1 degrades to empty cast and nil collection when TMDB omits them" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16"
      })
    end)

    assert {:ok, %{cast: [], collection: nil}} = HTTP.get_movie(27_205)
  end

  test "find_by_external_id/2 sends the source and retains movie, TV, and episode results" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/find/500"
      assert conn.params["external_source"] == "tvdb_id"

      Req.Test.json(conn, %{
        "movie_results" => [
          %{"id" => 10, "title" => "Movie", "release_date" => "2008-01-01"}
        ],
        "tv_results" => [
          %{"id" => 20, "name" => "Series", "first_air_date" => "2008-01-20"}
        ],
        "tv_episode_results" => [
          %{
            "id" => 30,
            "show_id" => 20,
            "season_number" => 4,
            "episode_number" => 15,
            "name" => "Episode",
            "air_date" => "2008-04-10"
          }
        ]
      })
    end)

    assert {:ok,
            [
              %{type: :movie, tmdb_id: 10, title: "Movie", year: 2008},
              %{type: :tv, tmdb_id: 20, title: "Series", year: 2008},
              %{
                type: :episode,
                tmdb_episode_id: 30,
                series_tmdb_id: 20,
                season_number: 4,
                episode_number: 15,
                title: "Episode",
                air_date: ~D[2008-04-10]
              }
            ]} = HTTP.find_by_external_id(500, :tvdb_id)
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
      assert conn.params["append_to_response"] == "external_ids,translations,credits"
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
      assert conn.params["append_to_response"] == "external_ids,translations,credits"

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
    # A series body without credits degrades to an empty cast rather than crashing.
    assert {:ok, %{cast: []}} = HTTP.get_series(7)
  end

  test "get_series/1 appends credits + carries top-billed cast" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.params["append_to_response"] == "external_ids,translations,credits"

      Req.Test.json(conn, %{
        "id" => 1396,
        "name" => "Breaking Bad",
        "first_air_date" => "2008-01-20",
        "seasons" => [%{"season_number" => 1}],
        "credits" => %{
          "cast" => [
            %{"id" => 4, "name" => "Walter", "character" => "Heisenberg", "order" => 0}
          ]
        }
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 1396,
              cast: [%{tmdb_id: 4, name: "Walter", character: "Heisenberg", profile_path: nil}]
            }} = HTTP.get_series(1396)
  end

  test "get_movie/1 stays canonical, prefers the locale region, and trims translations" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205"
      assert conn.params["append_to_response"] == "translations,credits"
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

  test "a non-map entry under results still parks instead of raising past the adult filter" do
    Req.Test.expect(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"results" => ["not-a-group"]})
    end)

    assert {:error, :unexpected_response} = HTTP.get_episode_groups(37_854)
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

  test "trending/1 sends the locale, tags movie/TV results, and drops persons" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/trending/all/week"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "media_type" => "movie",
            "id" => 27_205,
            "title" => "Inception",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg"
          },
          %{
            "media_type" => "tv",
            "id" => 1396,
            "name" => "Breaking Bad",
            "first_air_date" => "2008-01-20",
            "poster_path" => "/bb.jpg"
          },
          %{"media_type" => "person", "id" => 500, "name" => "Somebody Famous"}
        ]
      })
    end)

    assert {:ok, [movie, tv]} = HTTP.trending("fr")

    assert %{type: :movie, tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"} =
             movie

    assert tv == %{
             type: :tv,
             tmdb_id: 1396,
             title: "Breaking Bad",
             year: 2008,
             poster_path: "/bb.jpg",
             original_language: nil
           }
  end

  test "trending/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"status_message" => "slow down"})
    end)

    assert {:error, {:tmdb_status, 429}} = HTTP.trending("en")
  end

  test "trending/1 returns an error (not a raise) on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false})
    end)

    assert {:error, :unexpected_response} = HTTP.trending("en")
  end

  test "popular_movies/1 sends the locale and tags results type: :movie" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/popular"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 27_205,
            "title" => "Inception",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg"
          }
        ]
      })
    end)

    assert {:ok, [movie]} = HTTP.popular_movies("fr")
    assert %{type: :movie, tmdb_id: 27_205, title: "Inception", year: 2010} = movie
  end

  test "popular_movies/1 returns an error (not a raise) on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false})
    end)

    assert {:error, :unexpected_response} = HTTP.popular_movies("en")
  end

  test "popular_movies/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"status_message" => "down"})
    end)

    assert {:error, {:tmdb_status, 500}} = HTTP.popular_movies("en")
  end

  test "top_rated_movies/1 sends the locale and tags results type: :movie" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/top_rated"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [
          %{"id" => 278, "title" => "The Shawshank Redemption", "release_date" => "1994-09-23"}
        ]
      })
    end)

    assert {:ok, [%{type: :movie, tmdb_id: 278, title: "The Shawshank Redemption"}]} =
             HTTP.top_rated_movies("en")
  end

  test "now_playing_movies/1 sends the locale and tags results type: :movie" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/now_playing"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [%{"id" => 1, "title" => "New Release", "release_date" => "2026-07-01"}]
      })
    end)

    assert {:ok, [%{type: :movie, tmdb_id: 1, title: "New Release"}]} =
             HTTP.now_playing_movies("en")
  end

  test "discover_movies/2 sends with_genres + the locale and tags results type: :movie" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/discover/movie"
      assert conn.params["with_genres"] == "28"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [%{"id" => 603, "title" => "The Matrix", "release_date" => "1999-03-31"}]
      })
    end)

    assert {:ok, [%{type: :movie, tmdb_id: 603, title: "The Matrix"}]} =
             HTTP.discover_movies(28, "en")
  end

  test "discover_movies/2 returns an error on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false})
    end)

    assert {:error, :unexpected_response} = HTTP.discover_movies(28, "en")
  end

  test "popular_tv/1 sends the locale and tags results type: :tv" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/popular"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 1399,
            "name" => "Game of Thrones",
            "first_air_date" => "2011-04-17",
            "poster_path" => "/got.jpg"
          }
        ]
      })
    end)

    assert {:ok, [series]} = HTTP.popular_tv("fr")
    assert %{type: :tv, tmdb_id: 1399, title: "Game of Thrones", year: 2011} = series
  end

  test "popular_tv/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"status_message" => "down"})
    end)

    assert {:error, {:tmdb_status, 500}} = HTTP.popular_tv("en")
  end

  test "top_rated_tv/1 sends the locale and tags results type: :tv" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/top_rated"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [%{"id" => 1396, "name" => "Breaking Bad", "first_air_date" => "2008-01-20"}]
      })
    end)

    assert {:ok, [%{type: :tv, tmdb_id: 1396, title: "Breaking Bad"}]} =
             HTTP.top_rated_tv("en")
  end

  test "discover_tv/2 sends with_genres + the locale and tags results type: :tv" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/discover/tv"
      assert conn.params["with_genres"] == "10759"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [
          %{"id" => 1399, "name" => "Game of Thrones", "first_air_date" => "2011-04-17"}
        ]
      })
    end)

    assert {:ok, [%{type: :tv, tmdb_id: 1399, title: "Game of Thrones"}]} =
             HTTP.discover_tv(10_759, "en")
  end

  test "discover_tv/2 returns an error on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false})
    end)

    assert {:error, :unexpected_response} = HTTP.discover_tv(10_759, "en")
  end

  test "recommended_movies/2 hits the movie recommendations path and tags results type: :movie" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/movie/27205/recommendations"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{"id" => 157_336, "title" => "Interstellar", "release_date" => "2014-11-05"}
        ]
      })
    end)

    assert {:ok, [%{type: :movie, tmdb_id: 157_336, title: "Interstellar", year: 2014}]} =
             HTTP.recommended_movies(27_205, "fr")
  end

  test "recommended_movies/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"status_message" => "not found"})
    end)

    assert {:error, {:tmdb_status, 404}} = HTTP.recommended_movies(27_205, "en")
  end

  test "recommended_tv/2 hits the tv recommendations path and tags results type: :tv" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/tv/1399/recommendations"
      assert conn.params["language"] == "en-US"

      Req.Test.json(conn, %{
        "results" => [%{"id" => 1396, "name" => "Breaking Bad", "first_air_date" => "2008-01-20"}]
      })
    end)

    assert {:ok, [%{type: :tv, tmdb_id: 1396, title: "Breaking Bad"}]} =
             HTTP.recommended_tv(1399, "en")
  end

  test "search_person/2 sends the locale and normalizes person results" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/person"
      assert conn.params["query"] == "nolan"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 525,
            "name" => "Christopher Nolan",
            "profile_path" => "/nolan.jpg",
            "known_for_department" => "Directing"
          },
          %{
            "id" => 500,
            "name" => "No Department",
            "profile_path" => nil,
            "known_for_department" => nil
          }
        ]
      })
    end)

    assert {:ok,
            [
              %{
                tmdb_id: 525,
                title: "Christopher Nolan",
                year: nil,
                poster_path: "/nolan.jpg",
                department: "Directing"
              },
              %{
                tmdb_id: 500,
                title: "No Department",
                year: nil,
                poster_path: nil,
                department: nil
              }
            ]} = HTTP.search_person("nolan", "fr")
  end

  test "search_person/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"status_message" => "unavailable"})
    end)

    assert {:error, {:tmdb_status, 503}} = HTTP.search_person("nolan", "en")
  end

  test "search_person/2 returns an error on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"results" => %{}})
    end)

    assert {:error, :unexpected_response} = HTTP.search_person("nolan", "en")
  end

  test "search_collection/2 sends the locale and normalizes collection results" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/search/collection"
      assert conn.params["query"] == "matrix"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 2344,
            "name" => "The Matrix Collection",
            "poster_path" => "/matrix.jpg"
          }
        ]
      })
    end)

    assert {:ok,
            [
              %{
                tmdb_id: 2344,
                title: "The Matrix Collection",
                year: nil,
                poster_path: "/matrix.jpg"
              }
            ]} = HTTP.search_collection("matrix", "fr")
  end

  test "adult-flagged entries are dropped from every list response" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{
        "results" => [
          %{"id" => 1, "media_type" => "movie", "title" => "Drive", "adult" => false},
          %{"id" => 2, "media_type" => "movie", "title" => "Drive Me XXX", "adult" => true}
        ]
      })
    end)

    assert {:ok, [%{tmdb_id: 1}]} = HTTP.trending("en")
  end

  test "adult-flagged entries are dropped from person credits, collection parts and the cast strip" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      case conn.request_path do
        "/3/movie/7" ->
          Req.Test.json(conn, %{
            "id" => 7,
            "title" => "Drive",
            "credits" => %{
              "cast" => [
                %{"id" => 1, "name" => "Ryan", "order" => 0, "adult" => false},
                %{"id" => 2, "name" => "Someone Else", "order" => 1, "adult" => true}
              ]
            }
          })

        "/3/person/1" ->
          Req.Test.json(conn, %{
            "id" => 1,
            "name" => "Someone",
            "combined_credits" => %{
              "cast" => [
                %{"id" => 1, "media_type" => "movie", "title" => "Drive", "adult" => false},
                %{"id" => 2, "media_type" => "movie", "title" => "Drive Me XXX", "adult" => true}
              ],
              "crew" => []
            }
          })

        "/3/collection/9" ->
          Req.Test.json(conn, %{
            "id" => 9,
            "name" => "Drive Collection",
            "parts" => [
              %{"id" => 1, "title" => "Drive", "adult" => false},
              %{"id" => 2, "title" => "Drive Me XXX", "adult" => true}
            ]
          })
      end
    end)

    assert {:ok, %{credits: [%{tmdb_id: 1}], total_credits: 1}} = HTTP.get_person(1, "en")
    assert {:ok, %{parts: [%{tmdb_id: 1}]}} = HTTP.get_collection(9, "en")
    assert {:ok, %{cast: [%{tmdb_id: 1}]}} = HTTP.get_movie(7)
  end

  test "search_collection/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"status_message" => "slow down"})
    end)

    assert {:error, {:tmdb_status, 429}} = HTTP.search_collection("matrix", "en")
  end

  test "search_collection/2 returns an error on a 200 lacking a results list" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"success" => false})
    end)

    assert {:error, :unexpected_response} = HTTP.search_collection("matrix", "en")
  end

  test "get_person/2 sends the locale and normalizes, deduplicates, and caps credits" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/person/525"
      assert conn.params["append_to_response"] == "combined_credits"
      assert conn.params["language"] == "fr-FR"

      generated =
        for id <- 10..69 do
          %{
            "media_type" => "movie",
            "id" => id,
            "title" => "Movie #{id}",
            "release_date" => "2020-01-01",
            "poster_path" => "/#{id}.jpg",
            "popularity" => 100 - id
          }
        end

      Req.Test.json(conn, %{
        "id" => 525,
        "name" => "Christopher Nolan",
        "profile_path" => "/nolan.jpg",
        "known_for_department" => "Directing",
        "combined_credits" => %{
          "cast" =>
            [
              %{
                "media_type" => "movie",
                "id" => 1,
                "title" => "First Wins",
                "release_date" => "2010-07-16",
                "popularity" => 100
              },
              %{
                "media_type" => "tv",
                "id" => 1,
                "name" => "Same ID, Different Type",
                "first_air_date" => "2015-01-01",
                "popularity" => 99
              },
              %{
                "media_type" => "movie",
                "id" => 2,
                "title" => "Nil Popularity",
                "popularity" => nil
              },
              %{"media_type" => "person", "id" => 3, "name" => "Dropped", "popularity" => 1_000},
              %{"media_type" => "other", "id" => 4, "title" => "Dropped", "popularity" => 1_000}
            ] ++ generated,
          "crew" => [
            %{
              "media_type" => "movie",
              "id" => 1,
              "title" => "Duplicate Loses",
              "popularity" => 1
            },
            %{
              "media_type" => "tv",
              "id" => 500,
              "name" => "Crew Credit",
              "first_air_date" => "2018-02-03",
              "popularity" => 98
            }
          ]
        }
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 525,
              name: "Christopher Nolan",
              profile_path: "/nolan.jpg",
              department: "Directing",
              credits: credits,
              total_credits: 64
            }} = HTTP.get_person(525, "fr")

    assert length(credits) == 60

    assert [
             %{type: :movie, tmdb_id: 1, title: "First Wins", release_date: ~D[2010-07-16]},
             %{type: :tv, tmdb_id: 1, title: "Same ID, Different Type", year: 2015},
             %{type: :tv, tmdb_id: 500, title: "Crew Credit", year: 2018}
             | _
           ] = credits

    refute Enum.any?(credits, &(&1.tmdb_id in [2, 3, 4]))
    refute Enum.any?(credits, &(&1.title == "Duplicate Loses"))
  end

  test "get_person/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"status_message" => "not found"})
    end)

    assert {:error, {:tmdb_status, 404}} = HTTP.get_person(0, "en")
  end

  test "get_person/2 returns an error on a malformed 200 body" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"id" => 525, "combined_credits" => %{"cast" => []}})
    end)

    assert {:error, :unexpected_response} = HTTP.get_person(525, "en")
  end

  test "get_collection/2 sends the locale and normalizes parts in chronological order" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      assert conn.request_path == "/3/collection/2344"
      assert conn.params["language"] == "fr-FR"

      Req.Test.json(conn, %{
        "id" => 2344,
        "name" => "The Matrix Collection",
        "poster_path" => "/matrix.jpg",
        "parts" => [
          %{
            "id" => 3,
            "title" => "Undated",
            "release_date" => nil,
            "poster_path" => "/undated.jpg"
          },
          %{
            "id" => 2,
            "title" => "January 2010",
            "release_date" => "2010-01-05",
            "poster_path" => "/2010.jpg"
          },
          %{
            "id" => 1,
            "title" => "December 2009",
            "release_date" => "2009-12-31",
            "poster_path" => "/2009.jpg"
          }
        ]
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 2344,
              title: "The Matrix Collection",
              poster_path: "/matrix.jpg",
              parts: [
                %{
                  type: :movie,
                  tmdb_id: 1,
                  title: "December 2009",
                  release_date: ~D[2009-12-31]
                },
                %{
                  type: :movie,
                  tmdb_id: 2,
                  title: "January 2010",
                  release_date: ~D[2010-01-05]
                },
                %{type: :movie, tmdb_id: 3, title: "Undated", release_date: nil}
              ]
            }} = HTTP.get_collection(2344, "fr")
  end

  test "get_collection/2 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"status_message" => "failed"})
    end)

    assert {:error, {:tmdb_status, 500}} = HTTP.get_collection(2344, "en")
  end

  test "get_collection/2 returns an error on a malformed 200 body" do
    Req.Test.stub(Cinder.TMDBStub, fn conn ->
      Req.Test.json(conn, %{"id" => 2344, "parts" => %{}})
    end)

    assert {:error, :unexpected_response} = HTTP.get_collection(2344, "en")
  end
end
