defmodule Cinder.Download.Client.DownloadUrlRefusalTest do
  # Every download client refuses a release's own http(s) download_url that `Cinder.HTTPPolicy`
  # refuses from its text, as the permanent `:unsupported_download_url`, before any request or
  # DNS lookup (#1230). A redirect Location refused for the same reasons, and a refusal that
  # depends on DNS, keep their own reason. Not async: each test swaps the clients'
  # `url_resolver`, which the async client suites read.
  use ExUnit.Case, async: false

  alias Cinder.ConfigCase
  alias Cinder.Download.Client.{Nzbget, QBittorrent, Sabnzbd, Transmission}

  @origin "https://indexer.example"
  @pinned "93.184.216.34"

  @clients [
    {Transmission, Cinder.TransmissionStub, :torrent_fetch_status},
    {QBittorrent, Cinder.QBittorrentStub, :torrent_fetch_status},
    {Sabnzbd, Cinder.SabnzbdStub, :nzb_fetch_status},
    {Nzbget, Cinder.NzbgetStub, :nzb_fetch_status}
  ]

  # Each Location answers the fetch of `/redirect/<key>` with a 302.
  @redirects %{
    "userinfo" => {"https://user@other.example/a.torrent", :userinfo_not_allowed},
    "no-host" => {"https:///a.torrent", :missing_host},
    "port" => {"https://other.example:99999/a.torrent", :invalid_port},
    "fragment" => {"https://other.example/a.torrent#frag", :fragment_not_allowed},
    "invalid-host" => {"https://\xff.example/a.torrent", :invalid_url}
  }

  setup do
    test_pid = self()

    for {client, stub, _tag} <- @clients do
      ConfigCase.put_config(client,
        url_resolver: fn host ->
          send(test_pid, {:dns, host})
          resolve(host)
        end
      )

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:request, conn.host, conn.request_path})
        serve(conn)
      end)
    end

    :ok
  end

  defp resolve("loopback.example"), do: {:ok, [{127, 0, 0, 1}]}
  defp resolve("nxdomain.example"), do: {:error, :nxdomain}
  defp resolve(_host), do: {:ok, [{93, 184, 216, 34}]}

  defp serve(%{request_path: "/redirect/" <> key} = conn) do
    {location, _reason} = Map.fetch!(@redirects, key)

    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end

  defp serve(conn), do: Plug.Conn.send_resp(conn, 500, "")

  defp drain(acc \\ []) do
    receive do
      {:request, host, path} -> drain([{:request, host, path} | acc])
      {:dns, host} -> drain([{:dns, host} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp add(client, url, origin) do
    client.add(%{download_url: url, download_url_origin: origin, title: "Movie"},
      operation_key: "01234567-89ab-cdef-0123-456789abcdef"
    )
  end

  # Each row's answer and every request and lookup it made, per client.
  defp run(urls, origin) do
    for {client, _stub, _tag} <- @clients, url <- urls do
      {client, url, add(client, url, origin), drain()}
    end
  end

  defp expect(urls, answer_fun) do
    for {client, _stub, tag} <- @clients, url <- urls do
      {answer, effects} = answer_fun.(url, tag)
      {client, url, answer, effects}
    end
  end

  @refused_without_origin [
    "https://indexer.example/a b.torrent",
    "https://indexer.example/a>b.torrent",
    "https://indexer.example/a{b}.torrent",
    "https://indexer.example/a\"b.torrent",
    "https://indexer.example/a\\b.torrent",
    "https://in dexer.example/a.torrent",
    "https://indexer.example/" <> <<0xFF>> <> ".torrent",
    "https:///a.torrent",
    "http:foo",
    "HTTP:foo",
    "https://user@indexer.example/a.torrent",
    "https://indexer.example/a.torrent#frag",
    "https://indexer.example:99999/a.torrent",
    "https://indexer.example:0/a.torrent",
    "ftp://indexer.example/a.nzb",
    "indexer.example/a.nzb"
  ]

  test "add/2 refuses a download_url HTTPPolicy refuses from its text, before any request or lookup" do
    refused = fn _url, _tag -> {{:error, :unsupported_download_url}, []} end

    assert run(@refused_without_origin, nil) == expect(@refused_without_origin, refused)
  end

  @refused_with_origin [
    "https:///a.torrent",
    "http:foo",
    "https://in dexer.example/a.torrent",
    "https://user@indexer.example/a.torrent",
    "https://indexer.example/a.torrent#frag",
    "https://indexer.example:99999/a.torrent",
    "ftp://indexer.example/a.nzb"
  ]

  test "add/2 refuses such a download_url beside its source origin, before any request or lookup" do
    refused = fn _url, _tag -> {{:error, :unsupported_download_url}, []} end

    assert run(@refused_with_origin, @origin) == expect(@refused_with_origin, refused)
  end

  test "add/2 still fetches a download_url that URI.new/1 accepts" do
    url = "https://indexer.example/%zz.torrent"

    fetched = fn _url, tag ->
      {{:error, {tag, 500}}, [{:dns, "indexer.example"}, {:request, @pinned, "/%zz.torrent"}]}
    end

    assert run([url], nil) == expect([url], fetched)
  end

  # #1158 kept this pass-through: on the source's own origin, the lenient merge accepts a path
  # that `URI.new/1` rejects, and the unpinned request leaves with no lookup.
  test "add/2 still fetches a raw path on its source's own origin" do
    url = "https://indexer.example/a b.torrent"

    fetched = fn _url, tag ->
      {{:error, {tag, 500}}, [{:request, "indexer.example", "/a b.torrent"}]}
    end

    assert run([url], @origin) == expect([url], fetched)
  end

  test "add/2 keeps a refusal that depends on DNS" do
    urls = ["https://loopback.example/a.torrent", "https://nxdomain.example/a.torrent"]

    looked_up = fn url, _tag ->
      host = URI.parse(url).host

      reason =
        if host == "loopback.example", do: :forbidden_address, else: :dns_resolution_failed

      {{:error, reason}, [{:dns, host}]}
    end

    assert run(urls, nil) == expect(urls, looked_up)
  end

  # Prowlarr records an origin only for a download_url on that origin, so it never pairs an http
  # link with an https origin. `HTTPPolicy.text_refusal?/1` leaves the downgrade out.
  test "add/2 keeps :https_downgrade for an http download_url beside an https origin" do
    url = "http://indexer.example/a.torrent"
    refused = fn _url, _tag -> {{:error, :https_downgrade}, []} end

    assert run([url], @origin) == expect([url], refused)
  end

  test "add/2 keeps the reason it refuses a redirect Location for" do
    keys = Enum.sort(Map.keys(@redirects))
    urls = Enum.map(keys, &"https://indexer.example/redirect/#{&1}")

    redirected = fn url, _tag ->
      "https://indexer.example/redirect/" <> key = url
      {_location, reason} = Map.fetch!(@redirects, key)

      {{:error, reason}, [{:dns, "indexer.example"}, {:request, @pinned, "/redirect/#{key}"}]}
    end

    assert run(urls, nil) == expect(urls, redirected)
  end
end
