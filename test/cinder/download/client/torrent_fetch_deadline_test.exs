defmodule Cinder.Download.Client.TorrentFetchDeadlineTest do
  # Not async: `Cinder.Test.BoundedRequestTrace` sets a global trace pattern on
  # `HTTPPolicy.bounded_request/2,3`.
  use ExUnit.Case, async: false

  alias Cinder.Download.Client.{Nzbget, QBittorrent, Transmission}
  alias Cinder.Test.BoundedRequestTrace

  # Each fetch hop's `bounded_request` arguments, in call order. The client's own API calls go
  # through `bounded_request` too, so the fetch is told apart by its path.
  defp fetch_calls(tracer, paths) do
    tracer
    |> BoundedRequestTrace.calls()
    |> Enum.filter(fn
      [%Req.Request{url: %URI{path: path}} | _] -> path in paths
      _call -> false
    end)
  end

  # Both hops answer without a torrent, so `add` ends at the fetch whatever the client does next.
  defp redirect_then_404(conn) do
    case conn.request_path do
      "/file/1" ->
        conn
        |> Plug.Conn.put_resp_header("location", "/file/2")
        |> Plug.Conn.send_resp(302, "")

      "/file/2" ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp assert_deadline_is_receive_timeout(calls) do
    assert [_first_hop, _second_hop] = calls

    for call <- calls do
      assert [request, _max_bytes, 90_000] = call
      assert Req.Request.get_option(request, :receive_timeout) == 90_000
    end
  end

  test "qBittorrent's torrent fetch ends at its 90 s receive_timeout on each redirect hop" do
    Req.Test.stub(Cinder.QBittorrentStub, &redirect_then_404/1)
    tracer = BoundedRequestTrace.start()

    assert {:error, {:torrent_fetch_status, 404}} =
             QBittorrent.add(%{download_url: "https://tracker.test/file/1"})

    tracer
    |> fetch_calls(["/file/1", "/file/2"])
    |> assert_deadline_is_receive_timeout()
  end

  test "Transmission's torrent fetch ends at its 90 s receive_timeout on each redirect hop" do
    Req.Test.stub(Cinder.TransmissionStub, &redirect_then_404/1)
    tracer = BoundedRequestTrace.start()

    assert {:error, {:torrent_fetch_status, 404}} =
             Transmission.add(%{download_url: "https://tracker.test/file/1"}, [])

    tracer
    |> fetch_calls(["/file/1", "/file/2"])
    |> assert_deadline_is_receive_timeout()
  end

  # NZBGet's fetch shares `Fetch.bytes/3` with Transmission's but sets no receive_timeout, so it
  # keeps `bounded_request/2`'s default deadline.
  test "NZBGet's NZB fetch keeps bounded_request/2's default deadline" do
    Req.Test.stub(Cinder.NzbgetStub, &redirect_then_404/1)
    tracer = BoundedRequestTrace.start()

    assert {:error, {:nzb_fetch_status, 404}} =
             Nzbget.add(%{title: "Movie", download_url: "https://provider.test/file/1"}, [])

    assert [[_first_hop, _max_bytes], [_second_hop, _max_bytes_again]] =
             fetch_calls(tracer, ["/file/1", "/file/2"])
  end
end
