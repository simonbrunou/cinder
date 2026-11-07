defmodule Cinder.Download.Client.TransmissionTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.Transmission

  @hash "0123456789abcdef0123456789abcdef01234567"

  defp stub_rpc(handler), do: Req.Test.stub(Cinder.TransmissionStub, &serve_rpc(&1, handler))

  defp serve_rpc(conn, handler) do
    assert Plug.Conn.get_req_header(conn, "authorization") != []

    case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
      ["test-session"] ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        handler.(conn, Jason.decode!(body))

      [] ->
        conn
        |> Plug.Conn.put_resp_header("x-transmission-session-id", "test-session")
        |> Plug.Conn.send_resp(409, "")
    end
  end

  defp success(conn, arguments),
    do: Req.Test.json(conn, %{"result" => "success", "arguments" => arguments})

  defp configure_path_mapping(remote, local) do
    keys = [:transmission_remote_path_prefix, :transmission_local_path_prefix]
    original = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :transmission_remote_path_prefix, remote)
    Application.put_env(:cinder, :transmission_local_path_prefix, local)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)
  end

  test "add/2 submits a magnet and preserves existing labels while adding the operation marker" do
    stub_rpc(fn conn, request ->
      case request["method"] do
        "torrent-add" ->
          assert request["arguments"]["filename"] =~ "magnet:?"
          success(conn, %{"torrent-added" => %{"hashString" => @hash}})

        "torrent-get" ->
          assert request["arguments"]["ids"] == [@hash]
          success(conn, %{"torrents" => [%{"labels" => ["household"]}]})

        "torrent-set" ->
          assert Enum.sort(request["arguments"]["labels"]) ==
                   ["cinder-op-123", "household"]

          success(conn, %{})
      end
    end)

    assert {:ok, @hash} =
             Transmission.add(
               %{download_url: "magnet:?xt=urn:btih:#{@hash}&dn=Movie"},
               operation_key: "op-123"
             )
  end

  test "add/2 rejects an unparseable magnet instead of forwarding it raw" do
    stub_rpc(fn _conn, _request ->
      flunk("an unparseable magnet must never reach Transmission")
    end)

    bad = "magnet:?xt=urn:btih:#{@hash}&tr=http://192.168.1.10:8123/x?a=>"
    assert {:error, :unsupported_download_url} = Transmission.add(%{download_url: bad})
  end

  test "add/2 rejects a magnet that is not valid UTF-8 instead of raising" do
    stub_rpc(fn _conn, _request ->
      flunk("a magnet that is not valid UTF-8 must never reach Transmission")
    end)

    bad = "magnet:?xt=urn:btih:#{@hash}&dn=\xff"
    assert {:error, :unsupported_download_url} = Transmission.add(%{download_url: bad})
  end

  test "add/2 submits a magnet without a tracker whose decoded host is not valid UTF-8" do
    test_pid = self()
    good = "udp://good.example:1/a"

    stub_rpc(fn conn, request ->
      case request["method"] do
        "torrent-add" ->
          send(test_pid, {:submitted, request["arguments"]["filename"]})
          success(conn, %{"torrent-added" => %{"hashString" => @hash}})
      end
    end)

    magnet =
      "magnet:?xt=urn:btih:#{@hash}&dn=Movie" <>
        "&tr=#{URI.encode_www_form("http://\xff.example/announce")}" <>
        "&tr=#{URI.encode_www_form(good)}"

    assert {:ok, @hash} = Transmission.add(%{download_url: magnet})
    assert_received {:submitted, submitted}

    assert Enum.to_list(URI.query_decoder(URI.parse(submitted).query)) ==
             [{"xt", "urn:btih:#{@hash}"}, {"dn", "Movie"}, {"tr", good}]
  end

  # Transmission fetches through `Cinder.Download.Client.Fetch`, which follows the redirect (#1158).
  test "add/2 refuses a fetch redirect whose host is not valid UTF-8, before Transmission hears of it" do
    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
      if conn.host == "93.184.216.34" do
        conn
        |> Plug.Conn.put_resp_header("location", "https://\xff.example/file.torrent")
        |> Plug.Conn.send_resp(302, "")
      else
        flunk("Transmission must not be contacted when the fetch redirect is invalid")
      end
    end)

    assert {:error, :invalid_url} =
             Transmission.add(
               %{download_url: "https://tracker.test/dl/123"},
               operation_key: "op-123"
             )
  end

  test "add/2 fetches and submits bounded torrent bytes without a network request" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"

    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
      if conn.host == "93.184.216.34" do
        Req.Test.text(conn, torrent_bytes)
      else
        case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("x-transmission-session-id", "test-session")
            |> Plug.Conn.send_resp(409, "")

          ["test-session"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            request = Jason.decode!(body)

            case request["method"] do
              "torrent-add" ->
                assert Base.decode64!(request["arguments"]["metainfo"]) == torrent_bytes
                success(conn, %{"torrent-added" => %{"hashString" => @hash}})

              "torrent-get" ->
                success(conn, %{"torrents" => [%{"labels" => []}]})

              "torrent-set" ->
                assert request["arguments"]["labels"] == ["cinder-op-123"]
                success(conn, %{})
            end
        end
      end
    end)

    assert {:ok, @hash} =
             Transmission.add(
               %{download_url: "https://tracker.test/file.torrent"},
               operation_key: "op-123"
             )
  end

  # Serves the torrent fetch (the test resolver maps every host to 93.184.216.34) with `fetch`,
  # and the RPC endpoint with `handler` as `stub_rpc/1` does.
  defp stub_fetch_and_rpc(fetch, handler) do
    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
      if conn.host == "93.184.216.34", do: fetch.(conn), else: serve_rpc(conn, handler)
    end)
  end

  # Reports every request before it flunks, so a test can refute a request even when Req
  # swallows the stub's raise.
  defp report_requests do
    test_pid = self()

    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})
      flunk("no request may leave for this download_url: #{conn.host}#{conn.request_path}")
    end)
  end

  defp report_submission(test_pid) do
    fn conn, %{"method" => "torrent-add"} = request ->
      send(test_pid, {:submitted, request["arguments"]["filename"]})
      success(conn, %{"torrent-added" => %{"hashString" => @hash}})
    end
  end

  # RFC 3986 section 3.1: a URI scheme is case-insensitive, and an indexer may send `MAGNET:`.
  test "add/2 submits an upper- or mixed-case magnet as the lower-case link it submits" do
    stub_rpc(report_submission(self()))

    for scheme <- ["magnet", "MAGNET", "Magnet"] do
      url = "#{scheme}:?xt=urn:btih:#{@hash}&dn=Movie"
      assert Transmission.add(%{download_url: url}) == {:ok, @hash}
    end

    assert_received {:submitted, "magnet:?" <> _ = lower}
    assert_received {:submitted, ^lower}
    assert_received {:submitted, ^lower}
  end

  test "add/2 refuses an upper-case magnet it cannot parse, before any request" do
    report_requests()

    for url <- [
          "MAGNET:?xt=urn:btih:#{@hash}&dn=a b",
          "MAGNET:?xt=urn:btih:#{@hash}&dn=a>b",
          "MAGNET:?xt=urn:btih:#{@hash}&dn=\xff",
          "MAGNET:"
        ] do
      assert Transmission.add(%{download_url: url}) == {:error, :unsupported_download_url}
    end

    refute_received {:request, _, _}
  end

  test "add/2 fetches an HTTP:// or HTTPS:// torrent URL as it fetches the lower-case form" do
    test_pid = self()

    torrent_bytes =
      "d8:announce11:http://x/an4:infod6:lengthi5e4:name5:M.mkv12:piece lengthi16384eee"

    stub_fetch_and_rpc(
      fn conn ->
        send(test_pid, {:fetched, conn.scheme, conn.port, conn.request_path})
        Req.Test.text(conn, torrent_bytes)
      end,
      fn conn, %{"method" => "torrent-add"} = request ->
        send(test_pid, {:submitted, Base.decode64!(request["arguments"]["metainfo"])})
        success(conn, %{"torrent-added" => %{"hashString" => @hash}})
      end
    )

    for scheme <- ["http", "HTTP", "https", "HTTPS"] do
      url = "#{scheme}://indexer.example/file.torrent"
      assert Transmission.add(%{download_url: url}) == {:ok, @hash}
      assert_received {:submitted, ^torrent_bytes}
    end

    assert_received {:fetched, :http, 80, "/file.torrent"}
    assert_received {:fetched, :http, 80, "/file.torrent"}
    assert_received {:fetched, :https, 443, "/file.torrent"}
    assert_received {:fetched, :https, 443, "/file.torrent"}
  end

  test "add/2 refuses a download_url that is neither a magnet nor an http(s) URL, before any request" do
    report_requests()

    for url <- [
          "ftp://indexer.example/file.torrent",
          "indexer.example/file.torrent",
          "",
          # RFC 9110 section 4.2.1: an http(s) URI carries a `//` authority.
          "http:indexer.example/file.torrent",
          "HTTPS:/indexer.example/file.torrent"
        ] do
      assert Transmission.add(%{download_url: url}) == {:error, :unsupported_download_url}
    end

    refute_received {:request, _, _}
  end

  test "add/2 adds the magnet a fetch redirect to MAGNET: names, as it does for magnet:" do
    test_pid = self()

    stub_fetch_and_rpc(
      fn conn ->
        scheme = String.trim_leading(conn.request_path, "/dl/")

        conn
        |> Plug.Conn.put_resp_header("location", "#{scheme}:?xt=urn:btih:#{@hash}&dn=Movie")
        |> Plug.Conn.send_resp(302, "")
      end,
      report_submission(test_pid)
    )

    for scheme <- ["magnet", "MAGNET"] do
      url = "https://indexer.example/dl/#{scheme}"
      assert Transmission.add(%{download_url: url}) == {:ok, @hash}
    end

    assert_received {:submitted, "magnet:?" <> _ = lower}
    assert_received {:submitted, ^lower}
  end

  test "find_by_operation_key/1 and list_managed/0 use exact Cinder labels" do
    stub_rpc(fn conn, %{"method" => "torrent-get", "arguments" => arguments} ->
      if arguments["fields"] == ["hashString", "labels"] do
        success(conn, %{
          "torrents" => [
            %{"hashString" => @hash, "labels" => ["cinder-op-123"]},
            %{"hashString" => "other", "labels" => ["not-cinder-op-123"]}
          ]
        })
      else
        success(conn, %{
          "torrents" => [
            %{
              "hashString" => @hash,
              "labels" => ["cinder-op-123"],
              "status" => 6,
              "percentDone" => 1.0,
              "error" => 0,
              "uploadRatio" => 1.75,
              "secondsSeeding" => 7200
            },
            %{"hashString" => "manual", "labels" => []}
          ]
        })
      end
    end)

    assert {:ok, @hash} = Transmission.find_by_operation_key("op-123")

    assert {:ok,
            [
              %{
                id: @hash,
                operation_key: "op-123",
                state: :completed,
                ratio: 1.75,
                seeding_time: 7200
              }
            ]} = Transmission.list_managed()
  end

  test "status/1 normalizes completion metrics and translates the content path" do
    configure_path_mapping("/remote", "/media")

    stub_rpc(fn conn, %{"method" => "torrent-get"} ->
      success(conn, %{
        "torrents" => [
          %{
            "hashString" => @hash,
            "status" => 6,
            "percentDone" => 1.0,
            "rateDownload" => 0,
            "eta" => -1,
            "peersSendingToUs" => 3,
            "error" => 0,
            "errorString" => "",
            "downloadDir" => "/remote",
            "name" => "Movie"
          }
        ]
      })
    end)

    assert {:ok,
            %{
              state: :completed,
              progress: 1.0,
              speed: 0,
              eta: nil,
              seeders: 3,
              content_path: "/media/Movie"
            }} = Transmission.status(@hash)
  end

  test "status/1 keeps a downloading torrent active despite a tracker warning" do
    stub_rpc(fn conn, %{"method" => "torrent-get"} ->
      success(conn, %{
        "torrents" => [
          %{
            "hashString" => @hash,
            "status" => 4,
            "percentDone" => 0.4,
            "rateDownload" => 5000,
            "eta" => 120,
            "peersSendingToUs" => 2,
            "error" => 1,
            "errorString" => "Tracker warning: bad announce",
            "downloadDir" => "/downloads",
            "name" => "Movie"
          }
        ]
      })
    end)

    assert {:ok, %{state: :downloading, reason: "Tracker warning: bad announce"}} =
             Transmission.status(@hash)
  end

  test "status/1 keeps a completed torrent completed despite a tracker error" do
    stub_rpc(fn conn, %{"method" => "torrent-get"} ->
      success(conn, %{
        "torrents" => [
          %{
            "hashString" => @hash,
            "status" => 6,
            "percentDone" => 1.0,
            "rateDownload" => 0,
            "eta" => -1,
            "peersSendingToUs" => 0,
            "error" => 2,
            "errorString" => "Tracker gave an error",
            "downloadDir" => "/downloads",
            "name" => "Movie"
          }
        ]
      })
    end)

    assert {:ok, %{state: :completed, reason: "Tracker gave an error"}} =
             Transmission.status(@hash)
  end

  test "status/1 still reports :error for a genuine local error" do
    stub_rpc(fn conn, %{"method" => "torrent-get"} ->
      success(conn, %{
        "torrents" => [
          %{
            "hashString" => @hash,
            "status" => 4,
            "percentDone" => 0.4,
            "rateDownload" => 0,
            "eta" => -1,
            "peersSendingToUs" => 0,
            "error" => 3,
            "errorString" => "No space left on device",
            "downloadDir" => "/downloads",
            "name" => "Movie"
          }
        ]
      })
    end)

    assert {:ok, %{state: :error, reason: "No space left on device"}} =
             Transmission.status(@hash)
  end

  test "list_managed/0 reports downloading and completed states despite tracker warnings" do
    stub_rpc(fn conn, %{"method" => "torrent-get"} ->
      success(conn, %{
        "torrents" => [
          %{
            "hashString" => @hash,
            "labels" => ["cinder-op-warn"],
            "status" => 4,
            "percentDone" => 0.4,
            "error" => 1,
            "uploadRatio" => 0.0,
            "secondsSeeding" => 0
          },
          %{
            "hashString" => "other",
            "labels" => ["cinder-op-error"],
            "status" => 6,
            "percentDone" => 1.0,
            "error" => 2,
            "uploadRatio" => 2.0,
            "secondsSeeding" => 3600
          }
        ]
      })
    end)

    assert {:ok, entries} = Transmission.list_managed()

    assert [
             %{id: @hash, operation_key: "op-warn", state: :downloading},
             %{id: "other", operation_key: "op-error", state: :completed}
           ] = entries
  end

  test "files/1 and remove/2 implement the behavior contract" do
    stub_rpc(fn conn, request ->
      case request["method"] do
        "torrent-get" ->
          success(conn, %{
            "torrents" => [%{"files" => [%{"name" => "Movie/video.mkv"}]}]
          })

        "torrent-remove" ->
          assert request["arguments"] == %{
                   "ids" => [@hash],
                   "delete-local-data" => false
                 }

          success(conn, %{})
      end
    end)

    assert {:ok, ["Movie/video.mkv"]} = Transmission.files(@hash)
    assert :ok = Transmission.remove(@hash, delete_files: false)
  end

  test "health/0 requires label-capable Transmission and validates path mapping" do
    configure_path_mapping(nil, nil)

    stub_rpc(fn conn, %{"method" => "session-get"} ->
      success(conn, %{"version" => "4.0.6", "rpc-version" => 17})
    end)

    assert :ok = Transmission.health()
  end
end
