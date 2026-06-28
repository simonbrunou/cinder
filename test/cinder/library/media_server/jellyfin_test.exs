defmodule Cinder.Library.MediaServer.JellyfinTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Jellyfin

  import Cinder.ConfigCase

  defp put_config(overrides), do: put_config(Jellyfin, overrides)

  test "scan/1 posts to /Library/Refresh with the api token and returns :ok on 204" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/Library/Refresh"
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(204)
      |> Req.Test.text("")
    end)

    assert :ok = Jellyfin.scan(:movies)
  end

  test "scan/1 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.scan(:movies)
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

  test "health/0 with no url returns {:error, :not_configured} instead of raising" do
    put_config(url: nil)
    assert {:error, :not_configured} = Jellyfin.health()
  end

  test "scan/1 with no api key omits the header and surfaces a clean error (no raise)" do
    put_config(api_key: nil)

    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == []
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.scan(:movies)
  end
end
