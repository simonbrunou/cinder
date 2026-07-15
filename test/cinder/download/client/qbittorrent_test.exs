defmodule Cinder.Download.Client.QBittorrentTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.QBittorrent

  # 40 hex chars; the impl lowercases what it extracts.
  @hash "0123456789ABCDEF0123456789ABCDEF01234567"

  # Serves the login round-trip (setting the SID cookie), then delegates the
  # action request to `action_fun`.
  defp stub_qbit(action_fun) do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/api/v2/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        _ ->
          action_fun.(conn)
      end
    end)
  end

  test "add/1 logs in, posts the magnet, and returns the lowercased btih hash" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/add"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["SID=testsid"]
      Req.Test.text(conn, "Ok.")
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"

    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: magnet})
  end

  test "add/2 tags the torrent with the operation key" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/add"
      assert conn.params["tags"] == "cinder-op-123"
      Req.Test.text(conn, "Ok.")
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"

    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: magnet}, operation_key: "op-123")
  end

  test "find_by_operation_key/1 returns the tagged torrent's infohash" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/app/webapiVersion" ->
          Req.Test.text(conn, "2.8.3")

        "/api/v2/torrents/info" ->
          assert conn.params["tag"] == "cinder-op-123"
          Req.Test.json(conn, [%{"hash" => "abc123", "tags" => "other,cinder-op-123"}])
      end
    end)

    assert {:ok, "abc123"} = QBittorrent.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 returns :not_found for an unused tag" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/app/webapiVersion" -> Req.Test.text(conn, "2.8.3")
        "/api/v2/torrents/info" -> Req.Test.json(conn, [])
      end
    end)

    assert :not_found = QBittorrent.find_by_operation_key("missing")
  end

  test "find_by_operation_key/1 rejects an older WebAPI before tag lookup" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/app/webapiVersion"
      Req.Test.text(conn, "2.8.2")
    end)

    assert {:error, {:unsupported_webapi_version, "2.8.2"}} =
             QBittorrent.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 cannot accept an unrelated torrent if tag filtering is ignored" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/app/webapiVersion" -> Req.Test.text(conn, "2.8.3")
        "/api/v2/torrents/info" -> Req.Test.json(conn, [%{"hash" => "wrong", "tags" => "other"}])
      end
    end)

    assert :not_found = QBittorrent.find_by_operation_key("op-123")
  end

  defp stub_torrent_flow(torrent_bytes) do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"tracker.test", _} ->
          Req.Test.text(conn, torrent_bytes)

        {_, "/api/v2/auth/login"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        {_, "/api/v2/torrents/add"} ->
          Req.Test.text(conn, "Ok.")

        _ ->
          flunk("unexpected request: #{conn.request_path}")
      end
    end)
  end

  test "add/1 rejects an unsupported download_url scheme without calling qBittorrent" do
    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: "udp://tracker.test/announce"})

    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: nil})
  end

  test "add/1 fetches a .torrent URL, computes its infohash, and uploads it" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)

    stub_torrent_flow(torrent_bytes)

    assert {:ok, ^expected} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/123.torrent"})
  end

  test "add/1 returns :bad_torrent when the URL returns a non-torrent body" do
    stub_torrent_flow("<html>nope</html>")

    assert {:error, :bad_torrent} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/x"})
  end

  test "status/1 normalizes a completed torrent" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/info"
      assert conn.params["hashes"] == "abc123"
      Req.Test.json(conn, [%{"state" => "uploading", "progress" => 1.0}])
    end)

    assert {:ok, %{state: :completed, progress: 1.0}} = QBittorrent.status("abc123")
  end

  test "status/1 normalizes per-download measurements" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [
        %{"state" => "downloading", "progress" => 0.42, "dlspeed" => 1_500_000, "eta" => 90}
      ])
    end)

    assert {:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: 90}} =
             QBittorrent.status("abc123")
  end

  test "status/1 omits qBittorrent's sentinel eta" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [
        %{
          "state" => "downloading",
          "progress" => 0.42,
          "dlspeed" => 1_500_000,
          "eta" => 8_640_000
        }
      ])
    end)

    assert {:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: nil}} =
             QBittorrent.status("abc123")
  end

  test "status/1 returns :not_found when qBittorrent knows no such torrent" do
    stub_qbit(fn conn -> Req.Test.json(conn, []) end)

    assert {:error, :not_found} = QBittorrent.status("missing")
  end

  test "add/1 surfaces a login failure when no SID is returned" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn -> Req.Test.text(conn, "Fails.") end)

    magnet = "magnet:?xt=urn:btih:#{@hash}"
    assert {:error, :login_failed} = QBittorrent.add(%{download_url: magnet})
  end

  test "status/1 carries the content_path from the torrent info" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [
        %{
          "state" => "uploading",
          "progress" => 1.0,
          "content_path" => "/downloads/Movie/Movie.mkv"
        }
      ])
    end)

    assert {:ok, %{state: :completed, content_path: "/downloads/Movie/Movie.mkv"}} =
             QBittorrent.status("abc123")
  end

  test "status/1 classifies a relocating (moving) torrent as still downloading" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [%{"state" => "moving", "progress" => 1.0}])
    end)

    assert {:ok, %{state: :downloading}} = QBittorrent.status("abc123")
  end

  test "health/0 logs in and pings webapiVersion, returning :ok on 200" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/app/webapiVersion"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["SID=testsid"]
      Req.Test.text(conn, "2.8.5")
    end)

    assert :ok = QBittorrent.health()
  end

  test "health/0 returns an error when login fails" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn -> Req.Test.text(conn, "Fails.") end)

    assert {:error, :login_failed} = QBittorrent.health()
  end

  test "health/0 rejects old and malformed WebAPI versions" do
    for version <- ["2.8.2", "not-a-version"] do
      stub_qbit(fn conn -> Req.Test.text(conn, version) end)

      assert {:error, {:unsupported_webapi_version, ^version}} = QBittorrent.health()
    end
  end

  test "add/2 adopts an already-present torrent on a 409 duplicate response (magnet path)" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/torrents/add" ->
          Plug.Conn.send_resp(conn, 409, "")

        "/api/v2/torrents/info" ->
          assert conn.params["hashes"] == "0123456789abcdef0123456789abcdef01234567"
          Req.Test.json(conn, [%{"hash" => "0123456789abcdef0123456789abcdef01234567"}])

        "/api/v2/torrents/addTags" ->
          assert conn.params["hashes"] == "0123456789abcdef0123456789abcdef01234567"
          assert conn.params["tags"] == "cinder-op-999"
          Req.Test.text(conn, "Ok.")
      end
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"

    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: magnet}, operation_key: "op-999")
  end

  test "add/1 adopts an already-present torrent on 409 without an operation_key (no tag call)" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/torrents/add" ->
          Plug.Conn.send_resp(conn, 409, "")

        "/api/v2/torrents/info" ->
          Req.Test.json(conn, [%{"hash" => "0123456789abcdef0123456789abcdef01234567"}])

        "/api/v2/torrents/addTags" ->
          flunk("must not tag without an operation_key")
      end
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"

    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: magnet})
  end

  test "add/1 parks (does not retry forever) when a 409 torrent can't be found by infohash" do
    stub_qbit(fn conn ->
      case conn.request_path do
        "/api/v2/torrents/add" -> Plug.Conn.send_resp(conn, 409, "")
        "/api/v2/torrents/info" -> Req.Test.json(conn, [])
      end
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"
    assert {:error, :add_rejected} = QBittorrent.add(%{download_url: magnet})
  end

  test "add/1 adopts an already-present .torrent-URL-fetched release on a 409" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"tracker.test", _} ->
          Req.Test.text(conn, torrent_bytes)

        {_, "/api/v2/auth/login"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        {_, "/api/v2/torrents/add"} ->
          Plug.Conn.send_resp(conn, 409, "")

        {_, "/api/v2/torrents/info"} ->
          assert conn.params["hashes"] == expected
          Req.Test.json(conn, [%{"hash" => expected}])
      end
    end)

    assert {:ok, ^expected} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/123.torrent"})
  end

  test "add/1 accepts a base32 magnet and returns its lowercase-hex infohash" do
    raw = :crypto.hash(:sha, "phase5")
    b32 = Base.encode32(raw, padding: false)
    expected = Base.encode16(raw, case: :lower)

    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/add"
      Req.Test.text(conn, "Ok.")
    end)

    assert {:ok, ^expected} =
             QBittorrent.add(%{download_url: "magnet:?xt=urn:btih:#{b32}&dn=x"})
  end

  test "health/0 handles qBittorrent v5.x auth: a 204 login and a QBT_SID_<port> cookie" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/api/v2/auth/login" ->
          # qBittorrent >= 5.x answers /auth/login with 204 No Content and names the
          # session cookie QBT_SID_<port>, not the legacy 200 + "SID=".
          conn
          |> Plug.Conn.put_resp_header(
            "set-cookie",
            "QBT_SID_8080=v5sid; HttpOnly; SameSite=Lax; path=/"
          )
          |> Plug.Conn.send_resp(204, "")

        "/api/v2/app/webapiVersion" ->
          # the session cookie must be threaded back under its real name
          assert Plug.Conn.get_req_header(conn, "cookie") == ["QBT_SID_8080=v5sid"]
          Req.Test.text(conn, "2.15.1")
      end
    end)

    assert :ok = QBittorrent.health()
  end

  test "remove/2 logs in and posts the hash with deleteFiles=true by default" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/delete"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["SID=testsid"]
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["hashes"] == "abc123"
      assert params["deleteFiles"] == "true"
      Req.Test.text(conn, "")
    end)

    assert :ok = QBittorrent.remove("abc123", [])
  end

  test "remove/2 honours delete_files: false" do
    stub_qbit(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["deleteFiles"] == "false"
      Req.Test.text(conn, "")
    end)

    assert :ok = QBittorrent.remove("abc123", delete_files: false)
  end

  test "remove/2 surfaces a login failure" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn -> Req.Test.text(conn, "Fails.") end)
    assert {:error, :login_failed} = QBittorrent.remove("abc123", [])
  end

  test "add/1 routes a redirect-to-magnet through the magnet add path" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"tracker.test", _} ->
          # Prowlarr-style proxied downloadUrl for a magnet-only indexer.
          conn
          |> Plug.Conn.put_resp_header("location", "magnet:?xt=urn:btih:#{@hash}&dn=Movie")
          |> Plug.Conn.send_resp(302, "")

        {_, "/api/v2/auth/login"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        {_, "/api/v2/torrents/add"} ->
          Req.Test.text(conn, "Ok.")
      end
    end)

    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/123"})
  end

  test "add/1 follows an http redirect to the torrent file" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"tracker.test", "/dl/123"} ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://tracker.test/real.torrent")
          |> Plug.Conn.send_resp(302, "")

        {"tracker.test", "/real.torrent"} ->
          Req.Test.text(conn, torrent_bytes)

        {_, "/api/v2/auth/login"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        {_, "/api/v2/torrents/add"} ->
          Req.Test.text(conn, "Ok.")
      end
    end)

    assert {:ok, ^expected} = QBittorrent.add(%{download_url: "https://tracker.test/dl/123"})
  end

  test "add/1 rejects a redirect to a non-http scheme" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "ftp://tracker.test/file.torrent")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/123"})
  end

  test "login cools down after a definitive auth failure: one attempt per process" do
    parent = self()

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      send(parent, :login_attempted)
      Req.Test.text(conn, "Fails.")
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}"

    assert {:error, :login_failed} = QBittorrent.add(%{download_url: magnet})
    assert_received :login_attempted

    # Second call in the same (poller-like) process skips the login entirely.
    assert {:error, :login_failed} = QBittorrent.add(%{download_url: magnet})
    refute_received :login_attempted
  end

  test "login does not forward credentials across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Process.delete({QBittorrent, :login_cooldown})

      Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
        if conn.host == "attacker.test" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:attacker_called, body})
          Req.Test.text(conn, "Fails.")
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/login")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:qbittorrent_status, ^status}} = QBittorrent.health()
      refute_received {:attacker_called, _}
    end
  end

  test "action requests do not forward the SID cookie across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
        case {conn.host, conn.request_path} do
          {_, "/api/v2/auth/login"} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
            |> Req.Test.text("Ok.")

          {"attacker.test", _} ->
            send(parent, {:attacker_called, Plug.Conn.get_req_header(conn, "cookie")})
            Req.Test.text(conn, "2.8.5")

          _ ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://attacker.test/info")
            |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:qbittorrent_status, ^status}} = QBittorrent.health()
      refute_received {:attacker_called, _}
    end
  end

  test "add/1 rejects an oversized torrent response before upload" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      assert conn.host == "tracker.test"
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 10 * 1024 * 1024 + 1))
    end)

    assert {:error, :response_too_large} =
             QBittorrent.add(%{download_url: "https://tracker.test/oversized.torrent"})
  end

  test "add/1 rejects an unsafe torrent URL before the request" do
    assert {:error, :forbidden_address} =
             QBittorrent.add(%{download_url: "http://127.0.0.1/private.torrent"})
  end

  test "add/1 allows a private URL proven to share the configured indexer origin" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/file/1" ->
          assert conn.host == "127.0.0.1"

          conn
          |> Plug.Conn.put_resp_header("location", "/file/2")
          |> Plug.Conn.send_resp(302, "")

        "/file/2" ->
          assert conn.host == "127.0.0.1"
          Req.Test.text(conn, torrent_bytes)

        "/api/v2/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        "/api/v2/torrents/add" ->
          Req.Test.text(conn, "Ok.")
      end
    end)

    assert {:ok, ^expected} =
             QBittorrent.add(%{
               download_url: "http://127.0.0.1:9696/file/1",
               download_url_origin: "http://127.0.0.1:9696"
             })
  end

  test "add/1 never restores indexer-origin trust after a cross-origin redirect" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"127.0.0.1", "/file/1"} ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://tracker.test/step")
          |> Plug.Conn.send_resp(302, "")

        {"tracker.test", "/step"} ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://127.0.0.1:9696/private.torrent")
          |> Plug.Conn.send_resp(302, "")

        {"127.0.0.1", "/private.torrent"} ->
          flunk("an untrusted redirect chain must not regain private-origin access")
      end
    end)

    assert {:error, :forbidden_address} =
             QBittorrent.add(%{
               download_url: "https://127.0.0.1:9696/file/1",
               download_url_origin: "https://127.0.0.1:9696"
             })
  end

  test "add/1 revalidates and rejects an unsafe torrent redirect" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      if conn.host == "127.0.0.1" do
        flunk("unsafe redirect destination must not be requested")
      else
        conn
        |> Plug.Conn.put_resp_header("location", "https://127.0.0.1/private.torrent")
        |> Plug.Conn.send_resp(302, "")
      end
    end)

    assert {:error, :forbidden_address} =
             QBittorrent.add(%{download_url: "https://tracker.test/start.torrent"})
  end
end
