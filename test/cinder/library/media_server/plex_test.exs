defmodule Cinder.Library.MediaServer.PlexTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Plex

  # Test functions within a module run sequentially (ExUnit only parallelizes across
  # async modules), and only PlexTest reads this module's config — so an override
  # (restored on exit) can't race another test.
  defp put_config(overrides) do
    original = Application.get_env(:cinder, Plex)
    on_exit(fn -> Application.put_env(:cinder, Plex, original) end)
    Application.put_env(:cinder, Plex, Keyword.merge(original, overrides))
  end

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

  test "health/0 validates the configured section (token-checked) and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/library/sections/1"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]
      Req.Test.text(conn, "<MediaContainer/>")
    end)

    assert :ok = Plex.health()
  end

  test "scan/0 returns :plex_section_unset without hitting Plex when section is blank" do
    put_config(section: nil)
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, :plex_section_unset} = Plex.scan()
  end

  test "health/0 returns :plex_section_unset when section is unset (so /status shows red)" do
    put_config(section: "")
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, :plex_section_unset} = Plex.health()
  end

  test "scan/0 with no token omits the header and surfaces a clean error (no raise)" do
    put_config(token: nil)

    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == []
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan()
  end

  test "health/0 surfaces a bad token (401) as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.health()
  end
end
