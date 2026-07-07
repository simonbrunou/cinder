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
end
