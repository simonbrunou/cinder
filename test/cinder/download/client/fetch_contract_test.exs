defmodule Cinder.Download.Client.FetchContractTest do
  # Every download client fetches an http(s) download_url only through the `fetch:` function in
  # its `add/2` options, which `Cinder.Download` builds from the intent's indexer source (#1650).
  # In the test config each client's `fetch_plug` is the same Req.Test stub as its API, so a
  # fetch of its own shows as a request for the link's path.
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.{Nzbget, QBittorrent, Sabnzbd, Transmission}

  @origin "https://indexer.example"
  @link "#{@origin}/dl/1"
  @hash "0123456789abcdef0123456789abcdef01234567"
  @magnet "magnet:?xt=urn:btih:#{@hash}&dn=Movie"

  @torrent "d8:announce11:http://x/an4:infod6:lengthi5e4:name5:M.mkv12:piece lengthi16384eee"

  # Each client's fetch options apart from its test seams, as literals.
  @clients [
    {Transmission, Cinder.TransmissionStub, @torrent,
     [
       max_bytes: 10 * 1024 * 1024,
       error_tag: :torrent_fetch_status,
       allow_magnet: true,
       receive_timeout: 90_000
     ]},
    {QBittorrent, Cinder.QBittorrentStub, @torrent,
     [
       max_bytes: 10 * 1024 * 1024,
       error_tag: :torrent_fetch_status,
       allow_magnet: true,
       receive_timeout: 90_000
     ]},
    {Sabnzbd, Cinder.SabnzbdStub, "nzb-bytes",
     [max_bytes: 20 * 1024 * 1024, error_tag: :nzb_fetch_status, receive_timeout: 15_000]},
    {Nzbget, Cinder.NzbgetStub, "nzb-bytes",
     [max_bytes: 20 * 1024 * 1024, error_tag: :nzb_fetch_status]}
  ]

  @torrent_clients [Transmission, QBittorrent]

  setup do
    test_pid = self()

    # Records each request and answers 500, so a client that gets past its fetch stops at its
    # first call to its own API past qBittorrent's login.
    for {_client, stub, _bytes, _opts} <- @clients do
      Req.Test.stub(stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, stub, conn.request_path, body})
        answer(conn)
      end)
    end

    :ok
  end

  defp answer(%{request_path: "/api/v2/auth/login"} = conn) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
    |> Req.Test.text("Ok.")
  end

  defp answer(conn), do: Plug.Conn.send_resp(conn, 500, "")

  defp release(url), do: %{download_url: url, download_url_origin: @origin, title: "Movie"}

  defp recording_fetch(answer) do
    test_pid = self()

    fn url, origin, opts ->
      send(test_pid, {:fetch, url, origin, opts})
      answer
    end
  end

  defp requests(stub, acc \\ []) do
    receive do
      {:request, ^stub, path, body} -> requests(stub, [{path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seams(client) do
    config = Application.get_env(:cinder, client)
    [plug: Keyword.fetch!(config, :fetch_plug), resolver: Keyword.fetch!(config, :url_resolver)]
  end

  test "an http link is fetched once through fetch:, with the client's fetch options" do
    for {client, stub, bytes, fetch_opts} <- @clients do
      client.add(release(@link), operation_key: "op-1", fetch: recording_fetch({:ok, bytes}))

      assert_received {:fetch, @link, @origin, opts}
      refute_received {:fetch, _url, _origin, _opts}
      assert {client, Enum.sort(opts)} == {client, Enum.sort(fetch_opts ++ seams(client))}

      # The client went on to its own API with the bytes, and never fetched the link itself.
      seen = requests(stub)
      assert {client, seen != []} == {client, true}
      assert {client, Enum.filter(seen, &match?({"/dl/1", _}, &1))} == {client, []}
    end
  end

  test "an http link with no fetch: raises KeyError before any request" do
    for {client, stub, _bytes, _opts} <- @clients do
      assert_raise KeyError, ~r/:fetch/, fn ->
        client.add(release(@link), operation_key: "op-1")
      end

      assert {client, requests(stub)} == {client, []}
    end
  end

  test "a fetch: error is add/2's answer, with no call to the client's API" do
    for {client, stub, _bytes, _opts} <- @clients do
      assert {client, {:error, :some_tag}} ==
               {client,
                client.add(release(@link),
                  operation_key: "op-1",
                  fetch: recording_fetch({:error, :some_tag})
                )}

      assert_received {:fetch, @link, @origin, _opts}
      assert {client, requests(stub)} == {client, []}
    end
  end

  test "a torrent client adds the magnet a fetch: answers through its magnet path" do
    for client <- @torrent_clients, {^client, stub, _bytes, _opts} <- @clients do
      client.add(release(@link),
        operation_key: "op-1",
        fetch: recording_fetch({:magnet, @magnet})
      )

      assert_received {:fetch, @link, @origin, _opts}
      seen = requests(stub)
      assert {client, Enum.any?(seen, fn {_path, body} -> body =~ @hash end)} == {client, true}
      assert {client, Enum.filter(seen, &match?({"/dl/1", _}, &1))} == {client, []}
    end
  end

  test "a torrent client adds a magnet download_url with no fetch:" do
    for client <- @torrent_clients, {^client, stub, _bytes, _opts} <- @clients do
      client.add(release(@magnet), operation_key: "op-1")

      seen = requests(stub)
      assert {client, Enum.any?(seen, fn {_path, body} -> body =~ @hash end)} == {client, true}
    end
  end
end
