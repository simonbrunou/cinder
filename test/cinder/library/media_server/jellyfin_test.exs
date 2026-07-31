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

  test "list_users/0 reads /Users, taking an address-shaped name as the email" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/Users"
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == ["test-key"]

      Req.Test.json(conn, [
        %{"Id" => "abc123", "Name" => "kim@example.com"},
        %{"Id" => "def456", "Name" => "sam"},
        %{"Id" => "ghi789", "Name" => "Kim @ Home"}
      ])
    end)

    assert {:ok, users} = Jellyfin.list_users()

    assert users == [
             %{id: "abc123", email: "kim@example.com", username: "kim@example.com"},
             %{id: "def456", email: nil, username: "sam"},
             %{id: "ghi789", email: nil, username: "Kim @ Home"}
           ]
  end

  test "list_users/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.list_users()
  end

  test "list_users/0 returns :not_configured without hitting Jellyfin when the url is blank" do
    put_config(url: "")

    Req.Test.stub(Cinder.JellyfinStub, fn _conn ->
      raise "should not call an unconfigured server"
    end)

    assert {:error, :not_configured} = Jellyfin.list_users()
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

  test "scan/1 does not forward its token across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.JellyfinStub, fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "x-emby-token")})
          Req.Test.text(conn, "")
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/scan")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:jellyfin_status, ^status}} = Jellyfin.scan(:movies)
      refute_received {:attacker_called, _}
    end
  end

  test "health/0 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Jellyfin.health()
  end
end
