defmodule Cinder.Library.AudiobookServer.AudiobookshelfTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.AudiobookServer.Audiobookshelf

  import Cinder.ConfigCase

  defp put_config(overrides), do: put_config(Audiobookshelf, overrides)

  test "scan/0 posts to /api/libraries/:id/scan with the bearer token and returns :ok on 200" do
    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/libraries/lib_test/scan"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      conn |> Plug.Conn.put_status(200) |> Req.Test.text("")
    end)

    assert :ok = Audiobookshelf.scan()
  end

  test "scan/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:audiobookshelf_status, 401}} = Audiobookshelf.scan()
  end

  test "scan/0 returns :not_configured without a request when the url is blank" do
    put_config(url: "")

    Req.Test.stub(Cinder.AudiobookshelfStub, fn _conn ->
      raise "should not call an unconfigured server"
    end)

    assert {:error, :not_configured} = Audiobookshelf.scan()
  end

  test "scan/0 returns :not_configured without a request when the library id is blank" do
    put_config(library_id: "")

    Req.Test.stub(Cinder.AudiobookshelfStub, fn _conn ->
      raise "should not call a server with no configured library"
    end)

    assert {:error, :not_configured} = Audiobookshelf.scan()
  end

  test "scan/0 with no api key omits the header and surfaces a clean error (no raise)" do
    put_config(api_key: nil)

    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:audiobookshelf_status, 401}} = Audiobookshelf.scan()
  end

  test "scan/0 does not forward its token across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "authorization")})
          Req.Test.text(conn, "")
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/scan")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:audiobookshelf_status, ^status}} = Audiobookshelf.scan()
      refute_received {:attacker_called, _}
    end
  end

  test "health/0 GETs /api/libraries with the token and returns :ok on 200" do
    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/libraries"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      Req.Test.json(conn, %{"libraries" => [%{"id" => "lib_test", "name" => "Audiobooks"}]})
    end)

    assert :ok = Audiobookshelf.health()
  end

  test "health/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom")
    end)

    assert {:error, {:audiobookshelf_status, 500}} = Audiobookshelf.health()
  end

  test "health/0 with no url returns {:error, :not_configured} instead of raising" do
    put_config(url: nil)
    assert {:error, :not_configured} = Audiobookshelf.health()
  end

  test "health/0 does not require a configured library id" do
    put_config(library_id: nil)

    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      Req.Test.json(conn, %{"libraries" => []})
    end)

    assert :ok = Audiobookshelf.health()
  end

  test "health/0 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Audiobookshelf.health()
  end
end
