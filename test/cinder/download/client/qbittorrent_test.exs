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

  test "add/1 rejects a non-magnet download_url without calling qBittorrent" do
    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: "http://prowlarr/file/1.torrent"})
  end

  test "status/1 normalizes a completed torrent" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/info"
      assert conn.params["hashes"] == "abc123"
      Req.Test.json(conn, [%{"state" => "uploading", "progress" => 1.0}])
    end)

    assert {:ok, %{state: :completed, progress: 1.0}} = QBittorrent.status("abc123")
  end

  test "status/1 normalizes a still-downloading torrent" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [%{"state" => "downloading", "progress" => 0.42}])
    end)

    assert {:ok, %{state: :downloading, progress: 0.42}} = QBittorrent.status("abc123")
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
end
