defmodule Cinder.Accounts.PlexAuth.HTTPTest do
  # async: false — client_identifier/0 persists through Cinder.Settings, which
  # mutates global Application env via load_into_env/0 on every write.
  use Cinder.DataCase, async: false

  import Cinder.ConfigCase

  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.PlexAuth.HTTP

  test "create_pin/0 sends the required headers and parses id/code" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v2/pins"
      assert Plug.Conn.get_req_header(conn, "x-plex-product") == ["Cinder"]

      assert Plug.Conn.get_req_header(conn, "x-plex-client-identifier") == [
               PlexAuth.client_identifier()
             ]

      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"id" => 42, "code" => "ABCD", "authToken" => nil})
    end)

    assert {:ok, %{id: 42, code: "ABCD"}} = HTTP.create_pin()
  end

  test "check_pin/1 sends the client identifier and returns {:error, :pending} on a null authToken" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.request_path == "/api/v2/pins/42"

      assert Plug.Conn.get_req_header(conn, "x-plex-client-identifier") == [
               PlexAuth.client_identifier()
             ]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 42, "authToken" => nil})
    end)

    assert {:error, :pending} = HTTP.check_pin(42)
  end

  test "check_pin/1 returns {:ok, token} once authToken is set" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 42, "authToken" => "plex-token-123"})
    end)

    assert {:ok, "plex-token-123"} = HTTP.check_pin(42)
  end

  test "account/1 sends the token and parses id/email/username" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.request_path == "/api/v2/user"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["user-token"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 7, "email" => "person@example.com", "username" => "person"})
    end)

    assert {:ok, %{id: 7, email: "person@example.com", username: "person"}} =
             HTTP.account("user-token")
  end

  test "account/1 tolerates a managed account with no email" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 8, "email" => nil, "username" => "managed"})
    end)

    assert {:ok, %{id: 8, email: nil, username: "managed"}} = HTTP.account("user-token")
  end

  test "server_ids/1 keeps only resources whose provides mentions server" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.request_path == "/api/v2/resources"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["user-token"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json([
        %{"provides" => "server", "clientIdentifier" => "server-1"},
        %{"provides" => "player", "clientIdentifier" => "player-1"},
        %{"provides" => "server,client", "clientIdentifier" => "server-2"}
      ])
    end)

    assert {:ok, ["server-1", "server-2"]} = HTTP.server_ids("user-token")
  end

  test "server_machine_id/0 hits the configured local server's /identity" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.host == "localhost"
      assert conn.request_path == "/identity"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"MediaContainer" => %{"machineIdentifier" => "abc-123"}})
    end)

    assert {:ok, "abc-123"} = HTTP.server_machine_id()
  end

  test "server_machine_id/0 returns {:error, :not_configured} when the local server url is blank" do
    put_config(Cinder.Library.MediaServer.Plex, url: "")

    assert {:error, :not_configured} = HTTP.server_machine_id()
  end

  test "client_identifier/0 generates once and returns the same value on the second call" do
    first = PlexAuth.client_identifier()
    second = PlexAuth.client_identifier()

    assert first == second
    assert {:ok, _uuid} = Ecto.UUID.cast(first)
  end
end
