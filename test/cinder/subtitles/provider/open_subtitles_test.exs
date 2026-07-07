defmodule Cinder.Subtitles.Provider.OpenSubtitlesTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Provider.OpenSubtitles

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
             ai_translated: false
           }
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

  test "health/0 is :ok on a 200 from an api-key-only endpoint" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert conn.request_path == "/api/v1/infos/formats"
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert :ok = OpenSubtitles.health()
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
end
