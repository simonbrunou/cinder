defmodule Cinder.Subtitles.Provider.OpenSubtitlesTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Provider.OpenSubtitles

  import Cinder.ConfigCase

  setup do
    # Isolate the token cache between tests (persistent_term is global).
    on_exit(fn -> :persistent_term.erase({OpenSubtitles, :token}) end)
    :ok
  end

  test "search/1 sends Api-Key + query params and normalizes results" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]
      assert conn.request_path == "/api/v1/subtitles"
      params = URI.decode_query(conn.query_string)
      assert params["imdb_id"] == "0111161"
      assert params["languages"] == "en"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "attributes" => %{
              "language" => "en",
              "download_count" => 500,
              "hearing_impaired" => false,
              "ai_translated" => false,
              "files" => [%{"file_id" => 42}]
            }
          }
        ]
      })
    end)

    assert {:ok, [r]} = OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})

    assert r == %{
             file_id: 42,
             language: "en",
             downloads: 500,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: false
           }
  end

  test "search/1 sends the moviehash param and normalizes moviehash_match" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["moviehash"] == "0123456789abcdef"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "attributes" => %{
              "language" => "en",
              "download_count" => 5,
              "hearing_impaired" => false,
              "ai_translated" => false,
              "moviehash_match" => true,
              "files" => [%{"file_id" => 7}]
            }
          }
        ]
      })
    end)

    assert {:ok, [r]} =
             OpenSubtitles.search(%{
               imdb_id: "tt0111161",
               moviehash: "0123456789abcdef",
               languages: ["en"]
             })

    assert r == %{
             file_id: 7,
             language: "en",
             downloads: 5,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: true
           }
  end

  test "search/1 defaults moviehash_match to false when the attribute is absent" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{
            "attributes" => %{
              "language" => "en",
              "download_count" => 1,
              "files" => [%{"file_id" => 1}]
            }
          }
        ]
      })
    end)

    assert {:ok, [%{moviehash_match: false}]} =
             OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
  end

  test "download/1 logs in for a token, then downloads the link body" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-123"]
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/42.srt"})

        "/f/42.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
  end

  test "download/1 maps HTTP 406 to :quota_exceeded" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" -> Req.Test.json(conn, %{"token" => "jwt-123"})
        "/api/v1/download" -> Plug.Conn.send_resp(conn, 406, ~s({"message":"quota"}))
      end
    end)

    assert {:error, :quota_exceeded} = OpenSubtitles.download(42)
  end

  test "health/0 logs in — validating api-key + username/password — and is :ok on a token" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert conn.request_path == "/api/v1/login"
      assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]
      Req.Test.json(conn, %{"token" => "jwt-123"})
    end)

    assert :ok = OpenSubtitles.health()
  end

  test "health/0 is an error when /login rejects the credentials" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert conn.request_path == "/api/v1/login"
      Plug.Conn.send_resp(conn, 401, ~s({"message":"invalid credentials"}))
    end)

    assert {:error, {:http, 401}} = OpenSubtitles.health()
  end

  test "search/1 drops a malformed entry (missing \"attributes\") instead of raising" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{
            "attributes" => %{
              "language" => "en",
              "download_count" => 1,
              "files" => [%{"file_id" => 1}]
            }
          },
          %{"no_attributes_here" => true}
        ]
      })
    end)

    assert {:ok, [_, _]} = OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
  end

  test "download/1 retries exactly once on 401: re-logs-in and succeeds" do
    {:ok, download_attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          attempt = Agent.get_and_update(download_attempts, fn n -> {n, n + 1} end)

          if attempt == 0 do
            Plug.Conn.send_resp(conn, 401, ~s({"message":"unauthorized"}))
          else
            Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/42.srt"})
          end

        "/f/42.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
    assert Agent.get(download_attempts, & &1) == 2
  end

  test "download/1 bounds the 401 retry to exactly once (a persistent 401 does not loop)" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" -> Req.Test.json(conn, %{"token" => "jwt-123"})
        "/api/v1/download" -> Plug.Conn.send_resp(conn, 401, ~s({"message":"unauthorized"}))
      end
    end)

    assert {:error, {:http, 401}} = OpenSubtitles.download(42)
  end

  test "download/1 caches the token across calls: only one /login for two downloads" do
    {:ok, login_calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Agent.update(login_calls, &(&1 + 1))
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/42.srt"})

        "/f/42.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
    assert Agent.get(login_calls, & &1) == 1
  end

  test "health/0 does not forward API key or login JSON across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
        if conn.host == "attacker.test" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "api-key"), body})
          Req.Test.json(conn, %{"token" => "stolen"})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/login")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:http, ^status}} = OpenSubtitles.health()
      refute_received {:attacker_called, _, _}
    end
  end

  test "download/1 does not forward bearer auth or JSON across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      :persistent_term.put({OpenSubtitles, :token}, "jwt-123")

      Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
        if conn.host == "attacker.test" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "authorization"), body})
          Req.Test.json(conn, %{"link" => "https://attacker.test/stolen.srt"})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/download")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:http, ^status}} = OpenSubtitles.download(42)
      refute_received {:attacker_called, _, _}
    end
  end

  test "search/1 follows a same-origin redirect instead of failing (fixes #114)" do
    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
        case conn.request_path do
          "/api/v1/subtitles" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/api/v1/subtitles2")
            |> Plug.Conn.send_resp(status, "")

          "/api/v1/subtitles2" ->
            assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]

            Req.Test.json(conn, %{
              "data" => [
                %{
                  "attributes" => %{
                    "language" => "en",
                    "download_count" => 1,
                    "files" => [%{"file_id" => 1}]
                  }
                }
              ]
            })
        end
      end)

      assert {:ok, [%{file_id: 1}]} =
               OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
    end
  end

  test "download/1 follows a same-origin redirect on /login and /download (fixes #114)" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/api/v1/login2")
          |> Plug.Conn.send_resp(301, "")

        "/api/v1/login2" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-123"]

          conn
          |> Plug.Conn.put_resp_header("location", "/api/v1/download2")
          |> Plug.Conn.send_resp(307, "")

        "/api/v1/download2" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-123"]
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/42.srt"})

        "/f/42.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
  end

  test "search/1 emits query params in alphabetical order (fixes #142)" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      keys = conn.query_string |> URI.query_decoder() |> Enum.map(fn {k, _v} -> k end)
      assert keys == Enum.sort(keys)
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, []} =
             OpenSubtitles.search(%{
               imdb_id: "tt0111161",
               tmdb_id: 209_867,
               season: 1,
               episode: 29,
               moviehash: "0123456789abcdef",
               languages: ["fr"]
             })
  end

  test "search/1 follows a canonicalizing 301 without re-appending params (fixes #142)" do
    # The API 301s every first request to a canonical URL; it answers 200 only when the follow-up
    # query is EXACTLY the canonical one — a client that re-appends its params never converges.
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.query_string do
        "canonical=1" ->
          Req.Test.json(conn, %{"data" => [%{"attributes" => %{"files" => [%{"file_id" => 9}]}}]})

        _ ->
          conn
          |> Plug.Conn.put_resp_header("location", "/api/v1/subtitles?canonical=1")
          |> Plug.Conn.send_resp(301, "")
      end
    end)

    assert {:ok, [%{file_id: 9}]} =
             OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
  end

  test "search/1 fails cleanly (no infinite loop) when a same-origin redirect loop exceeds the hop cap" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      next =
        if conn.request_path == "/api/v1/subtitles",
          do: "/api/v1/subtitles2",
          else: "/api/v1/subtitles"

      conn
      |> Plug.Conn.put_resp_header("location", next)
      |> Plug.Conn.send_resp(301, "")
    end)

    assert {:error, :too_many_redirects} =
             OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
  end

  test "download/1 follows a validated subtitle redirect" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/start.srt"})

        "/start.srt" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/final.srt")
          |> Plug.Conn.send_resp(302, "")

        "/final.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
  end

  test "download/1 rejects an unsafe returned link before fetching it" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" -> Req.Test.json(conn, %{"token" => "jwt-123"})
        "/api/v1/download" -> Req.Test.json(conn, %{"link" => "http://127.0.0.1/a.srt"})
        _ -> flunk("unsafe subtitle link must not be fetched")
      end
    end)

    assert {:error, :forbidden_address} = OpenSubtitles.download(42)
  end

  test "download/1 rejects an oversized subtitle response" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/large.srt"})

        "/f/large.srt" ->
          Plug.Conn.send_resp(conn, 200, String.duplicate("x", 10 * 1024 * 1024 + 1))
      end
    end)

    assert {:error, :response_too_large} = OpenSubtitles.download(42)
  end

  test "download/1 strips configured secrets from the untrusted link and its redirects" do
    config = Application.fetch_env!(:cinder, OpenSubtitles)

    put_config(OpenSubtitles,
      req_options: [
        plug: {Req.Test, Cinder.OpenSubtitlesStub},
        retry: false,
        headers: [{"x-config-secret", "header-secret"}, {"cookie", "sid=cookie-secret"}],
        auth: {:bearer, "generic-secret"},
        body: "configured-secret-body"
      ]
    )

    :persistent_term.put({OpenSubtitles, :token}, "jwt-123")

    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.opensubtitles.test", "/api/v1/download"} ->
          assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-123"]
          assert Plug.Conn.get_req_header(conn, "x-config-secret") == ["header-secret"]
          assert Plug.Conn.get_req_header(conn, "cookie") == ["sid=cookie-secret"]
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/start.srt"})

        {"dl.opensubtitles.test", "/start.srt"} ->
          assert_untrusted_request_is_clean(conn)

          conn
          |> Plug.Conn.put_resp_header("location", "https://cdn.opensubtitles.test/final.srt")
          |> Plug.Conn.send_resp(307, "")

        {"cdn.opensubtitles.test", "/final.srt"} ->
          assert_untrusted_request_is_clean(conn)
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert config[:url_resolver]
    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
  end

  defp assert_untrusted_request_is_clean(conn) do
    assert conn.method == "GET"
    assert Plug.Conn.get_req_header(conn, "api-key") == []
    assert Plug.Conn.get_req_header(conn, "authorization") == []
    assert Plug.Conn.get_req_header(conn, "x-config-secret") == []
    assert Plug.Conn.get_req_header(conn, "cookie") == []
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    assert body == ""
  end
end
