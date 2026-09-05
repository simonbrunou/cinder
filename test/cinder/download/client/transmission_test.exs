defmodule Cinder.Download.Client.TransmissionTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.Transmission

  @hash "0123456789abcdef0123456789abcdef01234567"

  defp stub_rpc(handler) do
    Req.Test.stub(Cinder.TransmissionStub, fn conn ->
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
    end)
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
