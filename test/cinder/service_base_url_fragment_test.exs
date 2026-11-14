defmodule Cinder.ServiceBaseUrlFragmentTest do
  # A configured service base URL with a fragment reaches the same requests as the URL cut at its
  # `#` (#1323). Req joins a request's path onto `base_url` as text, so before the fix the path
  # landed in the fragment and the request went to the base URL's own path, which each client's
  # `Req.Test` stub saw as a `nil` path.
  # Not async: each test sets the base URL of clients whose async suites read it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Prowlarr
  alias Cinder.Books.Metadata.{Hardcover, OpenLibrary}
  alias Cinder.ConfigCase
  alias Cinder.Download.Client.{QBittorrent, Sabnzbd}
  alias Cinder.Library.AudiobookServer.Audiobookshelf
  alias Cinder.Library.MediaServer.{Jellyfin, Plex}
  alias Cinder.Library.MigrationSource.{Radarr, Readarr, Sonarr}
  alias Cinder.Subtitles.Translator.LibreTranslate

  defp json(conn), do: Req.Test.json(conn, %{})

  defp qbittorrent(conn) do
    case conn.request_path do
      "/api/v2/auth/login" ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
        |> Req.Test.text("Ok.")

      _other ->
        Req.Test.text(conn, "2.11.2")
    end
  end

  defp sabnzbd_add(conn) do
    case conn.request_path do
      "/api" -> Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["SABnzbd_nzo_abc"]})
      _nzb -> Req.Test.text(conn, "nzb-bytes")
    end
  end

  defp libretranslate(conn), do: Req.Test.json(conn, %{"translatedText" => ["Bonjour"]})

  # Each row: a name, the client, its URL config key, its test URL, its stub, how the stub
  # answers, the call, and the method and path of each request the call sends with the test URL.
  defp rows do
    [
      {"Prowlarr health/0", Prowlarr, :base_url, "http://prowlarr:9696", Cinder.ProwlarrStub,
       &json/1, &Prowlarr.health/0, [{"GET", "/api/v1/health"}]},
      {"Prowlarr search/1", Prowlarr, :base_url, "http://prowlarr:9696", Cinder.ProwlarrStub,
       &Req.Test.json(&1, []), fn -> Prowlarr.search("tt1375666") end,
       [{"GET", "/api/v1/search"}]},
      {"SABnzbd health/0", Sabnzbd, :base_url, "http://localhost:8080", Cinder.SabnzbdStub,
       &json/1, &Sabnzbd.health/0, [{"GET", "/api"}, {"GET", "/api"}]},
      {"SABnzbd add/1", Sabnzbd, :base_url, "http://localhost:8080", Cinder.SabnzbdStub,
       &sabnzbd_add/1, fn -> Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1?id=9"}) end,
       [{"GET", "/getnzb/1"}, {"POST", "/api"}]},
      {"qBittorrent login and health/0", QBittorrent, :base_url, "http://localhost:8080",
       Cinder.QBittorrentStub, &qbittorrent/1, &QBittorrent.health/0,
       [{"POST", "/api/v2/auth/login"}, {"GET", "/api/v2/app/webapiVersion"}]},
      {"Radarr health/0", Radarr, :base_url, "http://radarr:7878", Cinder.RadarrStub, &json/1,
       &Radarr.health/0, [{"GET", "/api/v3/system/status"}]},
      {"Sonarr health/0", Sonarr, :base_url, "http://sonarr:8989", Cinder.SonarrStub, &json/1,
       &Sonarr.health/0, [{"GET", "/api/v3/system/status"}]},
      {"Readarr health/0", Readarr, :base_url, "http://bookshelf:8787", Cinder.ReadarrStub,
       &json/1, &Readarr.health/0, [{"GET", "/api/v1/system/status"}]},
      {"Jellyfin health/0", Jellyfin, :url, "http://localhost:8096", Cinder.JellyfinStub, &json/1,
       &Jellyfin.health/0, [{"GET", "/System/Info"}]},
      {"Plex health/0", Plex, :url, "http://localhost:32400", Cinder.PlexStub, &json/1,
       &Plex.health/0, [{"GET", "/library/sections/1"}, {"GET", "/library/sections/2"}]},
      {"Audiobookshelf health/0", Audiobookshelf, :url, "http://localhost:13378",
       Cinder.AudiobookshelfStub, &json/1, &Audiobookshelf.health/0, [{"GET", "/api/libraries"}]},
      {"Hardcover health/0", Hardcover, :base_url, "http://bookinfo.test", Cinder.HardcoverStub,
       &json/1, &Hardcover.health/0, [{"GET", "/search"}]},
      {"Open Library health/0", OpenLibrary, :base_url, "https://openlibrary.org",
       Cinder.OpenLibraryStub, &json/1, &OpenLibrary.health/0, [{"GET", "/search.json"}]},
      {"LibreTranslate translate/2", LibreTranslate, :base_url, "https://libretranslate.test",
       Cinder.LibreTranslateStub, &libretranslate/1,
       fn -> LibreTranslate.translate(["Hello"], "fr") end, [{"POST", "/translate"}]}
    ]
  end

  # Runs `call` with the client's URL set to `url` and returns each request the stub saw.
  defp requests(client, key, url, stub, answer, call) do
    test_pid = self()
    ConfigCase.put_config(client, [{key, url}])

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:request, conn.method, conn.host, conn.request_path, conn.query_string})
      answer.(conn)
    end)

    call.()
    drain()
  end

  defp drain(acc \\ []) do
    receive do
      {:request, _method, _host, _path, _query} = request -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp method_and_path({:request, method, _host, path, _query}), do: {method, path}

  test "a base URL with a fragment sends the same requests as the URL without it" do
    for {name, client, key, url, stub, answer, call, expected} <- rows() do
      plain = requests(client, key, url, stub, answer, call)
      assert Enum.map(plain, &method_and_path/1) == expected, name

      assert requests(client, key, url <> "#frag", stub, answer, call) == plain, name
    end
  end

  test "Prowlarr cuts a base URL at its `#`, whatever follows it" do
    for {url, path} <- [
          {"http://prowlarr:9696#", "/api/v1/search"},
          {"http://prowlarr:9696/#frag", "/api/v1/search"},
          {"http://prowlarr:9696/prowlarr#frag", "/prowlarr/api/v1/search"}
        ] do
      requests =
        requests(
          Prowlarr,
          :base_url,
          url,
          Cinder.ProwlarrStub,
          &Req.Test.json(&1, []),
          fn -> Prowlarr.search("tt1375666") end
        )

      assert Enum.map(requests, &method_and_path/1) == [{"GET", path}], url
    end
  end

  test "LibreTranslate drops a base URL's trailing `/` before a fragment too" do
    requests =
      requests(
        LibreTranslate,
        :base_url,
        "https://libretranslate.test/#frag",
        Cinder.LibreTranslateStub,
        &libretranslate/1,
        fn -> LibreTranslate.translate(["Hello"], "fr") end
      )

    assert Enum.map(requests, &method_and_path/1) == [{"POST", "/translate"}]
  end

  # Without the `Req.Test` plug, which answers a URL with no scheme or host, such as the
  # `/translate` LibreTranslate builds from `#frag`, where Finch refuses it. With no host in the
  # configured text, no request can leave the VM. SABnzbd's NZB fetch keeps its `fetch_plug`.
  test "a base URL that is only a fragment makes each call return an error, with no exit" do
    Process.flag(:trap_exit, true)

    for {name, client, key, _url, _stub, _answer, call, _expected} <- rows() do
      req_options = :cinder |> Application.get_env(client) |> Keyword.fetch!(:req_options)

      ConfigCase.put_config(client, [
        {key, "#frag"},
        req_options: Keyword.delete(req_options, :plug)
      ])

      Req.Test.stub(Cinder.SabnzbdStub, &sabnzbd_add/1)

      # Req raises in the request task, which logs its crash.
      {result, _log} = with_log(call)
      assert match?({:error, _reason}, result), name
      refute_received {:EXIT, _pid, _reason}, name
    end
  end

  # Jellyfin's `scan/1` has no blank-URL guard, and Plex's `list_users/0` sets its own base URL
  # over the server URL, so both build a request from a URL that is not set.
  test "a server URL that is not set fails Jellyfin's scan and leaves Plex's plex.tv read" do
    Process.flag(:trap_exit, true)
    test_pid = self()
    ConfigCase.put_config(Jellyfin, url: nil)
    ConfigCase.put_config(Plex, url: nil)
    Req.Test.stub(Cinder.JellyfinStub, &json/1)

    Req.Test.stub(Cinder.PlexStub, fn conn ->
      send(test_pid, {:plex_request, conn.host, conn.request_path})
      Req.Test.json(conn, [])
    end)

    assert match?({:error, _reason}, Jellyfin.scan(:movie))
    Plex.list_users()

    assert_received {:plex_request, "plex.tv", "/api/v2/friends"}
    refute_received {:EXIT, _pid, _reason}
  end

  # A `nil` URL reaches the builder of every client without a blank-URL guard, through a config
  # key that holds `nil`. Open Library falls back to its default URL, which its stub answers.
  test "a URL that is set to nil makes each call return an error, with no exit" do
    Process.flag(:trap_exit, true)

    for {name, client, key, _url, stub, answer, call, _expected} <- rows() do
      ConfigCase.put_config(client, [{key, nil}])
      Req.Test.stub(stub, answer)

      {result, _log} = with_log(call)

      if client == OpenLibrary,
        do: assert(result == :ok, name),
        else: assert(match?({:error, _reason}, result), name)

      refute_received {:EXIT, _pid, _reason}, name
    end
  end

  test "qBittorrent's login sends the base URL without its fragment as its referer" do
    test_pid = self()
    ConfigCase.put_config(QBittorrent, base_url: "http://qbittorrent:8080#frag")

    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      if conn.request_path == "/api/v2/auth/login",
        do: send(test_pid, {:referer, Plug.Conn.get_req_header(conn, "referer")})

      qbittorrent(conn)
    end)

    QBittorrent.health()

    assert_received {:referer, ["http://qbittorrent:8080"]}
  end
end
