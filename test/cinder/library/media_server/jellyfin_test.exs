defmodule Cinder.Library.MediaServer.JellyfinTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Jellyfin

  test "scan/0 posts to /Library/Refresh with the api token and returns :ok on 204" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/Library/Refresh"
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(204)
      |> Req.Test.text("")
    end)

    assert :ok = Jellyfin.scan()
  end

  test "scan/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.scan()
  end

  test "health/0 GETs /System/Info with the token and returns :ok on 200" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/System/Info"
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == ["test-key"]
      Req.Test.json(conn, %{"Version" => "10.9.0"})
    end)

    assert :ok = Jellyfin.health()
  end

  test "health/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.health()
  end
end
