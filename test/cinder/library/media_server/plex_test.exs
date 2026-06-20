defmodule Cinder.Library.MediaServer.PlexTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Plex

  test "scan/0 refreshes the configured section with the token and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/library/sections/1/refresh"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.text("")
    end)

    assert :ok = Plex.scan()
  end

  test "scan/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan()
  end

  test "health/0 GETs /identity and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/identity"
      Req.Test.text(conn, "<MediaContainer/>")
    end)

    assert :ok = Plex.health()
  end

  test "health/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.text("err")
    end)

    assert {:error, {:plex_status, 500}} = Plex.health()
  end
end
