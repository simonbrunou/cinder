defmodule Cinder.Library.MediaServer.PlexTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Plex

  import Cinder.ConfigCase

  defp put_config(overrides), do: put_config(Plex, overrides)

  test "scan/1 refreshes the kind's section with the token and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/library/sections/1/refresh"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.text("")
    end)

    assert :ok = Plex.scan(:movies)
  end

  test "list_users/0 reads plex.tv's shared-user list with the server token" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "plex.tv"
      assert conn.request_path == "/api/v2/friends"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]

      Req.Test.json(conn, [
        %{"id" => 9001, "username" => "kim", "email" => "kim@example.com"},
        %{"id" => 9002, "title" => "Sam", "email" => ""},
        %{"uuid" => "no-id", "email" => "ghost@example.com"}
      ])
    end)

    assert {:ok, users} = Plex.list_users()

    assert users == [
             %{id: 9001, email: "kim@example.com", username: "kim"},
             %{id: 9002, email: nil, username: "Sam"}
           ]
  end

  test "list_users/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.list_users()
  end

  test "list_users/0 returns :not_configured without hitting plex.tv when the token is blank" do
    put_config(token: "")
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call plex.tv with no token" end)

    assert {:error, :not_configured} = Plex.list_users()
  end

  test "list_items/1 returns exact TMDB matches and title deep links" do
    put_config(web_url: "https://app.plex.tv")

    Req.Test.stub(Cinder.PlexStub, fn conn ->
      case conn.request_path do
        "/identity" ->
          assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
          Req.Test.json(conn, %{"MediaContainer" => %{"machineIdentifier" => "machine-1"}})

        "/library/sections/1/all" ->
          assert conn.query_string =~ "includeGuids=1"
          assert Plug.Conn.get_req_header(conn, "x-plex-container-size") == ["5000"]

          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "totalSize" => 3,
              "Metadata" => [
                %{
                  "ratingKey" => "42",
                  "type" => "movie",
                  "Guid" => [%{"id" => "imdb://tt1"}, %{"id" => "tmdb://27205"}]
                },
                %{"ratingKey" => "43", "type" => "movie", "Guid" => []},
                %{
                  "ratingKey" => "44",
                  "type" => "show",
                  "Guid" => [%{"id" => "tmdb://1399"}]
                }
              ]
            }
          })
      end
    end)

    assert {:ok,
            [
              %{
                id: "plex:machine-1:42",
                tmdb_id: 27_205,
                deep_link:
                  "https://app.plex.tv/desktop/#!/server/machine-1/details?key=%2Flibrary%2Fmetadata%2F42"
              }
            ]} = Plex.list_items(:movies)
  end

  test "list_items/1 rejects missing and inconsistent inventory totals" do
    for total <- [:missing, 0, 2] do
      Req.Test.stub(Cinder.PlexStub, fn conn ->
        case conn.request_path do
          "/identity" ->
            Req.Test.json(conn, %{"MediaContainer" => %{"machineIdentifier" => "machine-1"}})

          "/library/sections/1/all" ->
            container = %{"Metadata" => [%{"ratingKey" => "42"}]}

            container =
              if total == :missing, do: container, else: Map.put(container, "totalSize", total)

            Req.Test.json(conn, %{"MediaContainer" => container})
        end
      end)

      assert {:error, :partial_inventory} = Plex.list_items(:movies)
    end
  end

  # Real Plex shapes (probed 2026-10-15): the `type=3` listing has no `leafCount`; the batched
  # `/library/metadata/<keys>` read does.
  defp stub_seasons(listed, metadata_fun) do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      case {conn.request_path, conn.query_string} do
        {"/identity", _} ->
          Req.Test.json(conn, %{"MediaContainer" => %{"machineIdentifier" => "machine-1"}})

        {"/library/sections/2/all", "type=3"} ->
          Req.Test.json(conn, %{
            "MediaContainer" => %{"totalSize" => length(listed), "Metadata" => listed}
          })

        {"/library/sections/2/all", "includeGuids=1"} ->
          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "totalSize" => 2,
              "Metadata" => [
                %{"ratingKey" => "44", "type" => "show", "Guid" => [%{"id" => "tmdb://1399"}]},
                %{"ratingKey" => "45", "type" => "show", "Guid" => [%{"id" => "tvdb://1"}]}
              ]
            }
          })

        {"/library/metadata/" <> keys, _} ->
          Req.Test.json(conn, %{"MediaContainer" => %{"Metadata" => metadata_fun.(keys)}})
      end
    end)
  end

  test "list_seasons/0 joins batched season episode counts to the show's TMDB id" do
    listed = [
      %{"ratingKey" => "100", "type" => "season", "parentRatingKey" => "44", "index" => 1},
      %{"ratingKey" => "101", "type" => "season", "parentRatingKey" => "44", "index" => 0},
      %{"ratingKey" => "102", "type" => "season", "parentRatingKey" => "45", "index" => 1},
      %{"ratingKey" => "103", "type" => "season", "parentRatingKey" => "44", "index" => 2}
    ]

    stub_seasons(listed, fn keys ->
      assert keys == "100,101,102,103"

      [
        %{"type" => "season", "parentRatingKey" => "44", "index" => 1, "leafCount" => 8},
        %{"type" => "season", "parentRatingKey" => "44", "index" => 0, "leafCount" => 2},
        %{"type" => "season", "parentRatingKey" => "45", "index" => 1, "leafCount" => 6},
        %{"type" => "season", "parentRatingKey" => "44", "index" => 2, "leafCount" => 0}
      ]
    end)

    # Specials, the show without a TMDB id and the empty season are all dropped.
    assert Plex.list_seasons() ==
             {:ok,
              [%{item_id: "plex:machine-1:44", tmdb_id: 1399, season_number: 1, episode_count: 8}]}
  end

  test "list_seasons/0 batches metadata reads and rejects a short or count-less batch" do
    listed =
      for n <- 1..150,
          do: %{
            "ratingKey" => "#{1000 + n}",
            "type" => "season",
            "parentRatingKey" => "44",
            "index" => n
          }

    test_pid = self()

    stub_seasons(listed, fn keys ->
      keys = String.split(keys, ",")
      send(test_pid, {:batch, length(keys)})

      for key <- keys,
          do: %{
            "type" => "season",
            "parentRatingKey" => "44",
            "index" => String.to_integer(key) - 1000,
            "leafCount" => 1
          }
    end)

    assert {:ok, seasons} = Plex.list_seasons()
    assert length(seasons) == 150
    assert_received {:batch, 100}
    assert_received {:batch, 50}

    stub_seasons(listed, fn keys ->
      keys |> String.split(",") |> tl() |> Enum.map(&%{"k" => &1})
    end)

    assert {:error, :partial_inventory} = Plex.list_seasons()

    # A season without an episode count is a shape Cinder doesn't understand: fail, don't drop.
    stub_seasons(listed, fn keys ->
      for key <- String.split(keys, ","),
          do: %{"type" => "season", "parentRatingKey" => "44", "index" => 1, "k" => key}
    end)

    assert {:error, :unexpected_response} = Plex.list_seasons()
  end

  test "list_seasons/0 returns :not_configured without hitting Plex when the URL is blank" do
    put_config(url: "")
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call an unconfigured Plex" end)

    assert {:error, :not_configured} = Plex.list_seasons()
  end

  test "scan/1 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan(:movies)
  end

  test "health/0 validates every kind's section (token-checked) and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      # health probes one section per kind (movies=1, tv=2); accept either.
      assert conn.request_path in ["/library/sections/1", "/library/sections/2"]
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]
      Req.Test.text(conn, "<MediaContainer/>")
    end)

    assert :ok = Plex.health()
  end

  test "scan/1 returns {:plex_section_unset, kind} without hitting Plex when section is blank" do
    put_config(movies_section: nil)
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.scan(:movies)
  end

  test "health/0 returns {:plex_section_unset, kind} when a kind's section is unset (red on /status)" do
    put_config(movies_section: "")
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.health()
  end

  test "scan/1 treats a whitespace-only section as unset (no malformed URL)" do
    put_config(movies_section: "   ")

    Req.Test.stub(Cinder.PlexStub, fn _conn ->
      raise "should not call Plex with a blank section"
    end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.scan(:movies)
  end

  test "scan/1 with no token omits the header and surfaces a clean error (no raise)" do
    put_config(token: nil)

    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == []
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan(:movies)
  end

  test "health/0 surfaces a bad token (401) as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.health()
  end

  test "scan/1 does not forward its token across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.PlexStub, fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "x-plex-token")})
          Req.Test.text(conn, "")
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/scan")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:plex_status, ^status}} = Plex.scan(:movies)
      refute_received {:attacker_called, _}
    end
  end

  test "health/0 rejects an oversized response" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 4 * 1024 * 1024 + 1))
    end)

    assert {:error, :response_too_large} = Plex.health()
  end
end
