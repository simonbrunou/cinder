defmodule Cinder.Download.Client.NzbgetTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.Nzbget

  @key "01234567-89ab-cdef-0123-456789abcdef"

  defp stub(handler) do
    Req.Test.stub(Cinder.NzbgetStub, fn conn ->
      case conn.request_path do
        "/jsonrpc" ->
          assert Plug.Conn.get_req_header(conn, "authorization") != []
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          handler.(conn, Jason.decode!(body))

        _ ->
          assert conn.host == "93.184.216.34"
          Req.Test.text(conn, "nzb-bytes")
      end
    end)
  end

  defp result(conn, value),
    do: Req.Test.json(conn, %{"id" => 1, "error" => nil, "result" => value})

  defp configure_path_mapping(remote, local) do
    keys = [:nzbget_remote_path_prefix, :nzbget_local_path_prefix]
    original = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :nzbget_remote_path_prefix, remote)
    Application.put_env(:cinder, :nzbget_local_path_prefix, local)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)
  end

  test "add/2 fetches NZB bytes and appends a recoverable title-bearing job" do
    stub(fn conn, %{"method" => "append", "params" => params} ->
      assert hd(params) == "Movie.cinder-#{@key}.nzb"
      assert Enum.at(params, 1) == Base.encode64("nzb-bytes")
      result(conn, 42)
    end)

    assert {:ok, "42"} =
             Nzbget.add(
               %{title: "Movie", download_url: "https://provider.test/file.nzb"},
               operation_key: @key
             )
  end

  # NZBGet fetches through `Cinder.Download.Client.Fetch`, which follows the redirect (#1158).
  test "add/2 refuses a fetch redirect whose host is not valid UTF-8, before NZBGet hears of it" do
    Req.Test.stub(Cinder.NzbgetStub, fn conn ->
      case conn.request_path do
        "/jsonrpc" ->
          flunk("NZBGet must not be contacted when the fetch redirect is invalid")

        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://\xff.example/file.nzb")
          |> Plug.Conn.send_resp(302, "")
      end
    end)

    assert {:error, :invalid_url} =
             Nzbget.add(%{download_url: "https://provider.test/redirect"}, operation_key: @key)
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:request, host, path} -> drain_requests([{host, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The torrent clients read a download_url's scheme in any letter case (#1195), and the shared
  # fetch helper reads a magnet `Location` that way too. NZBGet keeps answering each of these
  # links as it did before that change, and keeps refusing a redirect to a magnet.
  test "add/2 answers upper-case magnet and http(s) links, ftp and a redirect to MAGNET: as before" do
    test_pid = self()
    hash = "0123456789abcdef0123456789abcdef01234567"
    fetched = &[{"93.184.216.34", &1}]

    Req.Test.stub(Cinder.NzbgetStub, fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})

      case conn.request_path do
        "/dl/" <> scheme ->
          conn
          |> Plug.Conn.put_resp_header("location", "#{scheme}:?xt=urn:btih:#{hash}")
          |> Plug.Conn.send_resp(302, "")

        _ ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    for {url, expected, requests} <- [
          {"MAGNET:?xt=urn:btih:#{hash}&dn=Movie", {:error, :unsupported_scheme}, []},
          {"Magnet:?xt=urn:btih:#{hash}&dn=Movie", {:error, :unsupported_scheme}, []},
          {"MAGNET:?xt=urn:btih:#{hash}&dn=a b", {:error, " "}, []},
          {"MAGNET:?xt=urn:btih:#{hash}&dn=a>b", {:error, ">"}, []},
          {"MAGNET:", {:error, :unsupported_scheme}, []},
          {"HTTP://indexer.example/file.torrent", {:error, {:nzb_fetch_status, 500}},
           fetched.("/file.torrent")},
          {"HTTPS://indexer.example/file.torrent", {:error, {:nzb_fetch_status, 500}},
           fetched.("/file.torrent")},
          {"ftp://indexer.example/file.torrent", {:error, :unsupported_scheme}, []},
          {"https://indexer.example/dl/MAGNET", {:error, :unsupported_download_url},
           fetched.("/dl/MAGNET")},
          {"https://indexer.example/dl/magnet", {:error, :unsupported_download_url},
           fetched.("/dl/magnet")}
        ] do
      assert {url, Nzbget.add(%{download_url: url}, operation_key: @key)} == {url, expected}
      assert {url, drain_requests()} == {url, requests}
    end
  end

  test "find_by_operation_key/1 searches queue and history by the exact marker" do
    stub(fn conn, request ->
      case request["method"] do
        "listgroups" ->
          result(conn, [
            %{"NZBID" => 42, "NZBName" => "Movie.cinder-#{@key}"},
            %{"NZBID" => 7, "NZBName" => "Movie.cinder-#{@key}.sample"}
          ])

        "history" ->
          result(conn, [])
      end
    end)

    assert {:ok, "42"} = Nzbget.find_by_operation_key(@key)
  end

  test "status/1 follows a queue item into successful history and translates its path" do
    configure_path_mapping("/remote", "/media")

    stub(fn conn, request ->
      case request["method"] do
        "listgroups" ->
          result(conn, [])

        "history" ->
          result(conn, [
            %{
              "NZBID" => 42,
              "Status" => "SUCCESS/UNPACK",
              "FinalDir" => "",
              "DestDir" => "/remote/Movie"
            }
          ])
      end
    end)

    assert {:ok,
            %{
              state: :completed,
              progress: 1.0,
              content_path: "/media/Movie"
            }} = Nzbget.status("42")
  end

  test "status/1 normalizes queue progress and paused jobs as actionable errors" do
    stub(fn conn, %{"method" => "listgroups"} ->
      result(conn, [
        %{
          "NZBID" => 42,
          "Status" => "PAUSED",
          "FileSizeHi" => 0,
          "FileSizeLo" => 100,
          "RemainingSizeHi" => 0,
          "RemainingSizeLo" => 25
        }
      ])
    end)

    assert {:ok, %{state: :error, progress: 0.75, reason: reason}} = Nzbget.status("42")
    assert reason =~ "Paused"
  end

  test "files/1, list_managed/0, and remove/2 implement the behavior contract" do
    stub(fn conn, request ->
      case request["method"] do
        "listfiles" ->
          result(conn, [%{"Filename" => "Movie/video.mkv"}])

        "listgroups" ->
          result(conn, [
            %{
              "NZBID" => 42,
              "NZBName" => "Movie.cinder-#{@key}",
              "Status" => "DOWNLOADING",
              "FileSizeHi" => 0,
              "FileSizeLo" => 100,
              "RemainingSizeHi" => 0,
              "RemainingSizeLo" => 50
            }
          ])

        "history" ->
          result(conn, [])

        "editqueue" ->
          assert request["params"] in [
                   ["GroupFinalDelete", "", [42]],
                   ["HistoryFinalDelete", "", [42]]
                 ]

          result(conn, false)
      end
    end)

    assert {:ok, ["Movie/video.mkv"]} = Nzbget.files("42")

    assert {:ok, [%{id: "42", operation_key: @key, state: :downloading}]} =
             Nzbget.list_managed()

    assert :ok = Nzbget.remove("42")
  end

  test "list_managed/0 reports a finished job's completion time from its history entry" do
    stub(fn conn, request ->
      case request["method"] do
        "listgroups" ->
          result(conn, [])

        "history" ->
          result(conn, [
            %{
              "NZBID" => 43,
              "Name" => "Movie.cinder-#{@key}",
              "Status" => "SUCCESS/ALL",
              "HistoryTime" => 1_760_000_000
            }
          ])
      end
    end)

    assert {:ok, [%{id: "43", state: :completed, completed_at: 1_760_000_000}]} =
             Nzbget.list_managed()
  end

  test "health/0 probes the authenticated version endpoint and path mapping" do
    configure_path_mapping(nil, nil)
    stub(fn conn, %{"method" => "version"} -> result(conn, "25.4") end)
    assert :ok = Nzbget.health()
  end
end
