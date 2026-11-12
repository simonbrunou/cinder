defmodule Cinder.Acquisition.Indexer.ProwlarrBaseUrlTest do
  # Prowlarr records its configured base URL as the `download_url_origin` of a release whose link
  # is on that origin. `Cinder.HTTPPolicy.source_request_target/3` refuses an origin with user info
  # or a fragment from its text, so Prowlarr records the base URL with both removed (#1286).
  # Not async: each test sets the Prowlarr base URL, which the async `ProwlarrTest` reads, and the
  # end-to-end test swaps the clients' `url_resolver`, which the async client suites read.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.Indexer.Prowlarr
  alias Cinder.ConfigCase
  alias Cinder.Download.Client.{Nzbget, QBittorrent, Sabnzbd, Transmission}
  alias Cinder.HTTPPolicy

  # Each row: the configured base URL, a link on its origin, and the origin Prowlarr records.
  @stripped [
    {"http://user:pw@prowlarr:9696", "http://prowlarr:9696/1/download?apikey=k&link=abc",
     "http://prowlarr:9696"},
    {"http://user@prowlarr:9696", "http://prowlarr:9696/1/download", "http://prowlarr:9696"},
    {"http://@prowlarr:9696", "http://prowlarr:9696/1/download", "http://prowlarr:9696"},
    {"http://prowlarr:9696#frag", "http://prowlarr:9696/1/download", "http://prowlarr:9696"},
    {"http://prowlarr:9696#", "http://prowlarr:9696/1/download", "http://prowlarr:9696"},
    {"http://user:pw@prowlarr:9696#frag", "http://prowlarr:9696/1/download",
     "http://prowlarr:9696"},
    {"https://user:pw@prowlarr.example/prowlarr?x=1#frag",
     "https://prowlarr.example:443/prowlarr/1/download", "https://prowlarr.example/prowlarr?x=1"},
    {"http://user:pw@[::1]:9696", "http://[::1]:9696/1/download", "http://[::1]:9696"}
  ]

  # A base URL with neither part records its own text, even where `URI.to_string/1` would write
  # it another way (a default port, an upper-case scheme or host).
  @kept [
    {"http://prowlarr:9696", "http://prowlarr:9696/1/download"},
    {"http://prowlarr:80", "http://prowlarr/1/download"},
    {"HTTP://Prowlarr:9696", "http://prowlarr:9696/1/download"}
  ]

  defp search_with_base_url(base_url, results) do
    test_pid = self()
    ConfigCase.put_config(Prowlarr, base_url: base_url)

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      send(test_pid, {:prowlarr_request, conn.request_path})
      Req.Test.json(conn, results)
    end)

    Prowlarr.search("tt1375666")
  end

  defp result(title, link) do
    %{"title" => title, "size" => 1_000, "downloadUrl" => link, "protocol" => "torrent"}
  end

  defp origins(base_url, link) do
    {:ok, releases} = search_with_base_url(base_url, [result("Movie.2010.1080p-GRP", link)])
    Enum.map(releases, & &1.download_url_origin)
  end

  # The client's first check: the link with that origin, the resolver recording each lookup.
  defp first_check(link, origin) do
    test_pid = self()

    resolver = fn host ->
      send(test_pid, {:dns, host})
      {:ok, [{172, 18, 0, 5}]}
    end

    HTTPPolicy.source_request_target(link, origin, resolver)
  end

  test "the recorded origin drops the base URL's user info and fragment, and the client accepts it" do
    for {base_url, link, expected} <- @stripped do
      assert origins(base_url, link) == [expected], base_url
      assert HTTPPolicy.same_origin?(link, expected), base_url
      assert match?({:ok, %{connect_options: []}}, first_check(link, expected)), base_url
      refute_received {:dns, _host}, base_url
    end
  end

  test "a base URL with neither part records its own text" do
    for {base_url, link} <- @kept do
      assert origins(base_url, link) == [base_url], base_url
      assert match?({:ok, %{connect_options: []}}, first_check(link, base_url)), base_url
      refute_received {:dns, _host}, base_url
    end
  end

  test "a link on another origin and a magnet link still record no origin" do
    results = [
      result("Movie.2010.1080p-A", "http://indexer.example/1/download"),
      result("Movie.2010.1080p-B", "http://prowlarr:9697/1/download"),
      %{"title" => "Movie.2010.1080p-C", "magnetUrl" => "magnet:?xt=urn:btih:abc"}
    ]

    for base_url <- ["http://user:pw@prowlarr:9696", "http://prowlarr:9696#frag"] do
      assert {:ok, releases} = search_with_base_url(base_url, results)
      assert Enum.map(releases, & &1.download_url_origin) == [nil, nil, nil], base_url
    end
  end

  # The searches keep the configured base URL. Req joins the API path into a fragment, so that
  # search sends no path, which a real server reads as `/` (out of scope for #1286: update this
  # row once that is fixed).
  test "the search requests keep the configured base URL" do
    paths =
      for base_url <- ["http://user:pw@prowlarr:9696", "http://prowlarr:9696#frag"] do
        assert {:ok, _releases} = search_with_base_url(base_url, [])
        assert_received {:prowlarr_request, path}
        path
      end

    assert paths == ["/api/v1/search", nil]
  end

  describe "a release from a search with a user-info base URL" do
    @clients [
      {Transmission, Cinder.TransmissionStub, :torrent_fetch_status},
      {QBittorrent, Cinder.QBittorrentStub, :torrent_fetch_status},
      {Sabnzbd, Cinder.SabnzbdStub, :nzb_fetch_status},
      {Nzbget, Cinder.NzbgetStub, :nzb_fetch_status}
    ]

    setup do
      test_pid = self()

      for {client, stub, _tag} <- @clients do
        ConfigCase.put_config(client,
          url_resolver: fn host ->
            send(test_pid, {:dns, host})
            {:ok, [{172, 18, 0, 5}]}
          end
        )

        Req.Test.stub(stub, fn conn ->
          send(test_pid, {:request, conn.host, conn.request_path})
          Plug.Conn.send_resp(conn, 500, "")
        end)
      end

      :ok
    end

    defp drain(acc \\ []) do
      receive do
        {:request, host, path} -> drain([{:request, host, path} | acc])
        {:dns, host} -> drain([{:dns, host} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # Each client answers the stub's 500 for the link's path, fetched unpinned with no lookup.
    test "reaches the link's path on every client, with no DNS lookup" do
      link = "http://prowlarr:9696/1/download?apikey=k&link=abc"

      assert {:ok, [release]} =
               search_with_base_url("http://user:pw@prowlarr:9696", [result("Movie", link)])

      answers =
        for {client, _stub, _tag} <- @clients do
          answer = client.add(release, operation_key: "01234567-89ab-cdef-0123-456789abcdef")
          {client, answer, drain()}
        end

      assert answers ==
               for(
                 {client, _stub, tag} <- @clients,
                 do: {client, {:error, {tag, 500}}, [{:request, "prowlarr", "/1/download"}]}
               )
    end
  end
end
