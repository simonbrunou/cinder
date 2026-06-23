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

  test "scan/1 refreshes the kind's section with the token and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/library/sections/1/refresh"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.text("")
    end)

    assert :ok = Plex.scan(:movies)
  end

  test "scan/1 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan(:movies)
  end

  test "health/0 validates every kind's section (token-checked) and returns :ok on 200" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert conn.method == "GET"
      # health probes one section per kind (movies=1, tv=2); accept either.
      assert conn.request_path in ["/library/sections/1", "/library/sections/2"]
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-key"]
      Req.Test.text(conn, "<MediaContainer/>")
    end)

    assert :ok = Plex.health()
  end

  test "scan/1 returns {:plex_section_unset, kind} without hitting Plex when section is blank" do
    put_config(movies_section: nil)
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.scan(:movies)
  end

  test "health/0 returns {:plex_section_unset, kind} when a kind's section is unset (red on /status)" do
    put_config(movies_section: "")
    Req.Test.stub(Cinder.PlexStub, fn _conn -> raise "should not call Plex with no section" end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.health()
  end

  test "scan/1 treats a whitespace-only section as unset (no malformed URL)" do
    put_config(movies_section: "   ")

    Req.Test.stub(Cinder.PlexStub, fn _conn ->
      raise "should not call Plex with a blank section"
    end)

    assert {:error, {:plex_section_unset, :movies}} = Plex.scan(:movies)
  end

  test "scan/1 with no token omits the header and surfaces a clean error (no raise)" do
    put_config(token: nil)

    Req.Test.stub(Cinder.PlexStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == []
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.scan(:movies)
  end

  test "health/0 surfaces a bad token (401) as an error" do
    Req.Test.stub(Cinder.PlexStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:plex_status, 401}} = Plex.health()
  end
end
