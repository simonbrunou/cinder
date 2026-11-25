defmodule Cinder.Download.Client.TorrentFetchDeadlineTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.{Fetch, Nzbget, QBittorrent, Transmission}
  alias Cinder.Test.RequestDeadlines

  @fetch_paths ["/file/1", "/file/2"]

  # Each fetch hop's total deadline, in call order. The client's own API calls go through
  # `bounded_request` too, so the fetch is told apart by its path.
  defp fetch_deadlines(fun) do
    {result, requests} = RequestDeadlines.capture(fun)
    {result, for({path, deadline_ms} <- requests, path in @fetch_paths, do: deadline_ms)}
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

  test "qBittorrent's torrent fetch gives each redirect hop its 90 s receive_timeout as deadline" do
    Req.Test.stub(Cinder.QBittorrentStub, &redirect_then_404/1)

    assert {{:error, {:torrent_fetch_status, 404}}, [90_000, 90_000]} =
             fetch_deadlines(fn ->
               QBittorrent.add(%{download_url: "https://tracker.test/file/1"},
                 fetch: &Fetch.bytes/3
               )
             end)
  end

  test "Transmission's torrent fetch gives each redirect hop its 90 s receive_timeout as deadline" do
    Req.Test.stub(Cinder.TransmissionStub, &redirect_then_404/1)

    assert {{:error, {:torrent_fetch_status, 404}}, [90_000, 90_000]} =
             fetch_deadlines(fn ->
               Transmission.add(%{download_url: "https://tracker.test/file/1"},
                 fetch: &Fetch.bytes/3
               )
             end)
  end

  # NZBGet's fetch shares `Fetch.bytes/3` with Transmission's but keeps its 15 s receive_timeout,
  # so `bounded_request/2`'s 60 s default stays its deadline.
  test "NZBGet's NZB fetch keeps bounded_request/2's default deadline" do
    Req.Test.stub(Cinder.NzbgetStub, &redirect_then_404/1)

    assert {{:error, {:nzb_fetch_status, 404}}, [60_000, 60_000]} =
             fetch_deadlines(fn ->
               Nzbget.add(%{title: "Movie", download_url: "https://provider.test/file/1"},
                 fetch: &Fetch.bytes/3
               )
             end)
  end
end
