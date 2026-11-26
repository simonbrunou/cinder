defmodule Cinder.Acquisition.Indexer.CardigannGrabTest do
  # The Cardigann grab (#1672) through the real `Cinder.Acquisition.IndexerSource.Native`
  # `fetch_download/3`, on definitions and details pages written for Cinder
  # (`Cinder.CardigannFixtures`), behind the `Cinder.CardigannStub` plug. Every page runs through
  # a real parser worker, but in the worker crash and deadline tests, which start a stub `erl`.
  #
  # Not async: Native's clock and the Cardigann config are global.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.Indexer.Cardigann.Grab
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase
  alias Cinder.Download
  alias Cinder.Download.Client.QBittorrent
  alias Cinder.Download.GrabFailure
  alias Cinder.Indexers.Definitions.{Loader, LoadResult, Pin}
  alias Cinder.Indexers.ParserWorker
  alias Cinder.Test.OsProcess
  alias Cinder.TorrentFixture

  @now ~U[2026-11-26 12:00:00Z]
  @hash String.duplicate("ab", 20)
  @magnet "magnet:?xt=urn:btih:#{@hash}&dn=Movie"
  @details "https://t9.test/torrent/1"
  # A pattern that hits `BoundedRegex`'s match limit on `@backtracks`, and none other.
  @limit_pattern "^(a+)+$"
  @backtracks String.duplicate("a", 30) <> "!"

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  # The fetch options qBittorrent passes, without its plug and resolver, so each request goes to
  # the Cardigann stub, plus the provenance `Cinder.Download` adds.
  defp opts(indexer, extra) do
    Keyword.merge(
      [
        max_bytes: 1024 * 1024,
        error_tag: :torrent_fetch_status,
        allow_magnet: true,
        indexer_source: "native",
        indexer_id: indexer.id,
        credentials_version: indexer.credentials_version
      ],
      extra
    )
  end

  defp grab(indexer, link \\ @details, extra \\ []),
    do: Native.fetch_download(link, nil, opts(indexer, extra))

  defp t9!(edit \\ & &1, secrets \\ %{}) do
    [indexer] = setup!([{"t9.yml", torrent9_like(edit)}], [{"t9.yml", torrent9_base(), secrets}])
    indexer
  end

  # Two Torrent9-shaped indexers on the same site, one per edit, set up together.
  defp t9_pair!(edit_a, edit_b) do
    b = fn definition -> %{edit_b.(definition) | "id" => "cindertestt9b"} end

    setup!(
      [{"t9.yml", torrent9_like(edit_a)}, {"t9b.yml", torrent9_like(b)}],
      [{"t9.yml", torrent9_base(), %{}}, {"t9b.yml", torrent9_base(), %{}}]
    )
  end

  defp selectors(definition, selectors),
    do: put_in(definition, ["download", "selectors"], selectors)

  defp test_link(definition, on?),
    do: Map.put(definition, "testlinktorrent", if(on?, do: "true", else: "false"))

  defp with_password(definition) do
    Map.update!(definition, "settings", fn settings ->
      settings ++ [%{"name" => "password", "type" => "password", "label" => "Password"}]
    end)
  end

  @link_selector %{"selector" => "a.dl", "attribute" => "href"}

  # A filter that turns `hunter2` into a form the secret value check does not read, so only the
  # block's reference to the setting can refuse the link.
  @masked [%{"name" => "re_replace", "args" => ["hunter", "hun-ter"]}]

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  # Every request the stub received so far, with its headers, in order.
  defp sent do
    receive do
      {:cardigann_request, host, path, query, headers} ->
        [%{host: host, path: path, query: query, headers: headers} | sent()]
    after
      0 -> []
    end
  end

  defp page_with_cookie(conn, cookie, body) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", cookie)
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  defp erl_stub!(tmp, body) do
    path = Path.join(tmp, "erl")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    ConfigCase.put_env(:parser_worker_erl, path)
  end

  defp grab_deadline!(ms) do
    config = Application.get_env(:cinder, Cardigann, [])
    ConfigCase.put_env(Cardigann, Keyword.merge(config, grab_deadline_ms: ms))
  end

  defp grab_worker!(ms) do
    config = Application.get_env(:cinder, Cardigann, [])
    ConfigCase.put_env(Cardigann, Keyword.merge(config, grab_worker_ms: ms))
  end

  describe "the download block" do
    test "a details page's magnet link comes back as the magnet, from one page request" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      assert grab(indexer) == {:magnet, @magnet}
      assert requests() == [{"t9.test", "/torrent/1", %{}}]
    end

    test "a magnet quoted only in a script comes back through the second selector's filter" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(script: @magnet) end})

      assert grab(indexer) == {:magnet, @magnet}
      assert requests() == [{"t9.test", "/torrent/1", %{}}]
    end

    test "a details page with neither is the capped no-link tag, and records nothing" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(extra: "<p>gone</p>") end})

      assert grab(indexer) == {:error, {:cardigann_grab, :no_link}}
      assert GrabFailure.retry_class({:cardigann_grab, :no_link}) == :capped
      refute GrabFailure.drops?({:cardigann_grab, :no_link})
      assert %{backoff: :none, last_failure: nil, level: 0} = status(indexer)
    end

    test "a Usenet client's options refuse the magnet as an unsupported download URL" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      usenet = [allow_magnet: false, error_tag: :nzb_fetch_status]
      assert grab(indexer, @details, usenet) == {:error, :unsupported_download_url}

      # And a details link that redirects to the magnet.
      route(%{"t9.test" => fn _conn, _query -> {:redirect, 302, @magnet} end})
      assert grab(indexer, @details, usenet) == {:error, :unsupported_download_url}
    end

    test "a magnet that a password reaches through the download block is the secret-host tag" do
      with_key = %{
        "selector" => ~S|a[href^="magnet:?"]|,
        "attribute" => "href",
        "filters" => [
          %{"name" => "append", "args" => "&k={{ .Config.password }}"} | @masked
        ]
      }

      indexer = t9!(&(&1 |> with_password() |> selectors([with_key])), %{"password" => "hunter2"})
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
    end

    test "a details page that answers 503 is sent once and read by the check" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> {503, "busy"} end})

      assert grab(indexer) == {:error, {:torrent_fetch_status, 503}}
      assert length(requests()) == 1
    end

    test "a details link that redirects to a magnet comes back as the magnet" do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> {:redirect, 302, @magnet} end})

      assert grab(indexer) == {:magnet, @magnet}
    end

    test "a .DownloadUri.Query.<key> variable picks the link the details URL names" do
      indexer =
        t9!(
          &selectors(&1, [
            %{"selector" => ~S|a[data-id="{{ .DownloadUri.Query.id }}"]|, "attribute" => "href"}
          ])
        )

      other = "magnet:?xt=urn:btih:#{String.duplicate("cd", 20)}"

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_details(
            extra:
              ~s(<a data-id="41" href="#{other}">41</a><a data-id="42" href="#{@magnet}">42</a>)
          )
        end
      })

      assert grab(indexer, "https://t9.test/torrent?id=42") == {:magnet, @magnet}
      assert grab(indexer, "https://t9.test/torrent?id=41") == {:magnet, other}
      # A key given twice reads its first value, as Prowlarr's `.Query.<key>` does.
      assert grab(indexer, "https://t9.test/torrent?id=42&id=41") == {:magnet, @magnet}
    end

    test "a selector whose filter hits the regex limit is the limit tag; a later selector still wins" do
      limited = %{
        "selector" => "span.name",
        "filters" => [%{"name" => "re_replace", "args" => [@limit_pattern, "x"]}]
      }

      page = fn ->
        torrent9_details(extra: ~s(<span class="name">#{@backtracks}</span>), link: @magnet)
      end

      [indexer, both] =
        t9_pair!(&selectors(&1, [limited]), &selectors(&1, [limited, @link_selector]))

      route(%{"t9.test" => fn _conn, _query -> page.() end})
      assert grab(indexer) == {:error, {:cardigann_grab, :regex_limit}}
      assert GrabFailure.retry_class({:cardigann_grab, :regex_limit}) == :capped

      # The positive control: the same page with a selector after the limited one.
      assert grab(both) == {:magnet, @magnet}
    end

    test "a selector whose filter passes the output cap is the cap tag; a later selector still wins" do
      capped = %{
        "selector" => "span.name",
        "filters" => [%{"name" => "replace", "args" => ["a", String.duplicate("b", 100)]}]
      }

      # 1,000 `a` each replaced by 100 bytes build 100,000 bytes, past the 65,536-byte cap.
      page = fn ->
        torrent9_details(
          extra: ~s(<span class="name">#{String.duplicate("a", 1_000)}</span>),
          link: @magnet
        )
      end

      [indexer, both] =
        t9_pair!(&selectors(&1, [capped]), &selectors(&1, [capped, @link_selector]))

      route(%{"t9.test" => fn _conn, _query -> page.() end})
      assert grab(indexer) == {:error, {:cardigann_grab, :filter_output_cap}}
      assert GrabFailure.retry_class({:cardigann_grab, :filter_output_cap}) == :capped

      # The positive control: the same page with a selector after the capped one.
      assert grab(both) == {:magnet, @magnet}
    end

    test "a details page sent as gzip that does not inflate is the bad-page tag" do
      indexer = t9!()

      gzip = fn body ->
        fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, body)
        end
      end

      route(%{"t9.test" => gzip.("not gzip")})
      assert grab(indexer) == {:error, {:cardigann_grab, :bad_page}}
      assert GrabFailure.retry_class({:cardigann_grab, :bad_page}) == :capped

      # The positive control: the same page, gzipped, is read.
      route(%{"t9.test" => gzip.(:zlib.gzip(torrent9_details(link: @magnet)))})
      assert grab(indexer) == {:magnet, @magnet}
    end

    test "a selector link the URL rules refuse skips to the next selector, and ends as no link" do
      next = %{"selector" => "a.next", "attribute" => "href"}

      [indexer, alone] =
        t9_pair!(&selectors(&1, [@link_selector, next]), &selectors(&1, [@link_selector]))

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_details(
            link: "https://u:p@t9.test/dl/x.torrent",
            extra: ~s(<a class="next" href="#{@magnet}">x</a>)
          )
        end
      })

      assert grab(indexer) == {:magnet, @magnet}
      assert requests() == [{"t9.test", "/torrent/1", %{}}]

      assert grab(alone) == {:error, {:cardigann_grab, :no_link}}
      refute GrabFailure.drops?({:cardigann_grab, :no_link})
    end

    test "a value that is no http(s) URL or magnet skips to the next selector" do
      indexer =
        t9!(&selectors(&1, [@link_selector, %{"selector" => "a.next", "attribute" => "href"}]))

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_details(
            link: "javascript:void(0)",
            extra: ~s(<a class="next" href="#{@magnet}">x</a>)
          )
        end
      })

      assert grab(indexer) == {:magnet, @magnet}
    end

    test "a details page over the page cap is the page-too-large tag" do
      indexer = t9!()
      page = torrent9_details(link: @magnet)
      padded = page <> "<!--" <> String.duplicate("x", 2_097_152 - byte_size(page)) <> "-->"
      route(%{"t9.test" => fn _conn, _query -> padded end})

      assert grab(indexer) == {:error, {:cardigann_grab, :page_too_large}}
    end
  end

  describe "a link the selector resolves" do
    test "a relative value is resolved against the page URL and fetched once" do
      indexer = t9!(&(&1 |> selectors([@link_selector]) |> test_link(true)))
      torrent = TorrentFixture.minimal()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" -> torrent9_details(link: "/dl/x.torrent")
            "/dl/x.torrent" -> {200, torrent}
          end
        end
      })

      assert grab(indexer) == {:ok, torrent}
      assert requests() == [{"t9.test", "/torrent/1", %{}}, {"t9.test", "/dl/x.torrent", %{}}]
    end

    test "with testlinktorrent on, a body that is no bencode moves on to the next selector" do
      second = %{"selector" => "a.second", "attribute" => "href"}
      torrent = TorrentFixture.minimal()

      routes = %{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" ->
              torrent9_details(
                link: "/dl/x.torrent",
                extra: ~s(<a class="second" href="/dl/y.torrent">y</a>)
              )

            "/dl/x.torrent" ->
              {200, "<html>not a torrent</html>"}

            "/dl/y.torrent" ->
              {200, torrent}
          end
        end
      }

      [on, off] =
        t9_pair!(
          &(&1 |> selectors([@link_selector, second]) |> test_link(true)),
          &(&1 |> selectors([@link_selector, second]) |> test_link(false))
        )

      route(routes)
      assert grab(on) == {:ok, torrent}

      assert requests() == [
               {"t9.test", "/torrent/1", %{}},
               {"t9.test", "/dl/x.torrent", %{}},
               {"t9.test", "/dl/y.torrent", %{}}
             ]

      # Off, the first value is the answer the check reads: an HTML page.
      assert grab(off) == {:error, :challenge_page}
      assert requests() == [{"t9.test", "/torrent/1", %{}}, {"t9.test", "/dl/x.torrent", %{}}]
    end

    test "a link past the client's max_bytes is response-too-large" do
      indexer = t9!(&selectors(&1, [@link_selector]))

      route(%{
        "t9.test" => fn conn, _query ->
          if conn.request_path == "/torrent/1",
            do: torrent9_details(link: "/dl/x.torrent"),
            else: {200, "d" <> String.duplicate("x", 2_048)}
        end
      })

      assert grab(indexer, @details, max_bytes: 1_024) == {:error, :response_too_large}
    end

    test "with testlinktorrent on, a body that starts with d is returned with no second fetch" do
      indexer = t9!(&(&1 |> selectors([@link_selector]) |> test_link(true)))
      torrent = TorrentFixture.minimal()

      route(%{
        "t9.test" => fn conn, _query ->
          if conn.request_path == "/torrent/1",
            do: torrent9_details(link: "/dl/x.torrent"),
            else: {200, torrent}
        end
      })

      assert grab(indexer) == {:ok, torrent}
      assert length(requests()) == 2
    end

    test "with testlinktorrent on and no value passing, the answer is the no-link tag" do
      indexer = t9!(&(&1 |> selectors([@link_selector]) |> test_link(true)))

      route(%{
        "t9.test" => fn conn, _query ->
          if conn.request_path == "/torrent/1",
            do: torrent9_details(link: "/dl/x.torrent"),
            else: {200, "<html>not a torrent</html>"}
        end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :no_link}}
    end
  end

  describe "a definition without a download block" do
    test "the link is fetched directly and its bytes pass the check" do
      [indexer] = setup!([{"nyaa.yml", nyaa_like()}], [{"nyaa.yml", nyaa_base(), %{}}])
      torrent = TorrentFixture.minimal()
      route(%{"nyaa.test" => fn _conn, _query -> {200, torrent} end})

      assert grab(indexer, "https://nyaa.test/download/1.torrent") == {:ok, torrent}
      assert requests() == [{"nyaa.test", "/download/1.torrent", %{}}]
    end

    test "a link carrying a password off the credential hosts is never sent; on them it is" do
      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(&with_password/1)}], [
          {"nyaa.yml", nyaa_base(), %{"password" => "hunter2"}}
        ])

      torrent = TorrentFixture.minimal()

      route(%{
        "nyaa.test" => fn _conn, _query -> {200, torrent} end,
        "cdn.test" => fn _conn, _query -> {200, torrent} end
      })

      assert grab(indexer, "https://cdn.test/dl/1.torrent?k=hunter2") ==
               {:error, {:cardigann_grab, :secret_host}}

      assert requests() == []

      assert grab(indexer, "https://nyaa.test/dl/1.torrent?k=hunter2") == {:ok, torrent}
      assert requests() == [{"nyaa.test", "/dl/1.torrent", %{"k" => "hunter2"}}]
    end

    test "a 429 on the link starts the indexer's limit backoff" do
      [indexer] = setup!([{"nyaa.yml", nyaa_like()}], [{"nyaa.yml", nyaa_base(), %{}}])

      route(%{
        "nyaa.test" => fn conn, _query ->
          conn |> Plug.Conn.put_resp_header("retry-after", "600") |> Plug.Conn.send_resp(429, "")
        end
      })

      assert {:error, {:indexer_limit, until}} =
               grab(indexer, "https://nyaa.test/download/1.torrent")

      assert %{backoff: :limit, backoff_until: ^until} = status(indexer)
    end
  end

  describe "through the real qBittorrent adapter" do
    test "a Torrent9-shaped row's grab posts the sanitised magnet" do
      indexer = t9!()
      test_pid = self()
      bad = URI.encode_www_form("http://127.0.0.1/announce")
      good = URI.encode_www_form("udp://tracker.example:1337/announce")
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie&tr=#{bad}&tr=#{good}"

      Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
        case {Plug.Conn.get_req_header(conn, "host"), conn.request_path} do
          {["t9.test"], "/torrent/1"} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, torrent9_details(link: magnet))

          {_api, "/api/v2/auth/login"} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
            |> Req.Test.text("Ok.")

          {_api, "/api/v2/torrents/add"} ->
            send(test_pid, {:posted, conn.params["urls"]})
            Req.Test.text(conn, "Ok.")
        end
      end)

      release = %{download_url: @details, download_url_origin: nil}

      fetch =
        Download.fetch_function(Native,
          indexer_source: "native",
          indexer_id: indexer.id,
          credentials_version: indexer.credentials_version
        )

      assert {:ok, @hash} = QBittorrent.add(release, fetch: fetch)
      assert_received {:posted, urls}

      assert urls ==
               "magnet:?xt=urn%3Abtih%3A#{@hash}&dn=Movie&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce"
    end
  end

  describe "the copy at grab time" do
    test "a copy the current loader has not checked is a capped tag, with no request" do
      indexer = t9!()
      %{revision: revision} = Loader.fingerprint()
      sha = Cinder.DefinitionFixtures.blob_sha(bytes(torrent9_like()))

      {1, _} =
        Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^sha),
          set: [revision: revision - 1]
        )

      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      assert grab(indexer) == {:error, {:cardigann_grab, :definition_unchecked}}
      assert requests() == []
    end

    test "an indexer whose pinned copy is gone is changed, with no request" do
      indexer = t9!()
      {1, _} = Repo.delete_all(from(p in Pin, where: p.configured_indexer_id == ^indexer.id))
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      assert grab(indexer) == {:error, :indexer_changed}
      assert requests() == []
    end
  end

  describe "the one deadline" do
    test "the whole grab's deadline is 90 s" do
      assert Grab.deadline_ms() == 90_000
    end

    @tag :tmp_dir
    test "a link that holds its request past the time left ends at the grab's one deadline",
         %{tmp_dir: tmp} do
      grab_deadline!(5_000)
      indexer = t9!(&selectors(&1, [@link_selector]))
      # The worker starts 2 s late, then reads the page with the real `erl`, so the link's chain
      # starts at least 2 s into the grab: a fresh 5 s for that chain would end past 7 s.
      erl_stub!(tmp, "sleep 2\nexec '#{ParserWorker.erl_path()}' \"$@\"")

      route(%{
        "t9.test" => fn conn, _query ->
          if conn.request_path == "/torrent/1",
            do: torrent9_details(link: "/dl/x.torrent"),
            else: Process.sleep(:infinity)
        end
      })

      started = System.monotonic_time(:millisecond)
      assert grab(indexer) == {:error, {:cardigann_grab, :deadline}}
      elapsed = System.monotonic_time(:millisecond) - started

      assert [%{path: "/torrent/1"}, %{path: "/dl/x.torrent"}] = sent()
      assert elapsed >= 5_000
      assert elapsed < 6_500
      assert GrabFailure.retry_class({:cardigann_grab, :deadline}) == :capped
    end

    @tag :tmp_dir
    test "a worker past its own cap, with time left, is the parser-failed tag", %{tmp_dir: tmp} do
      assert Grab.worker_ms() == 30_000
      grab_deadline!(10_000)
      grab_worker!(500)
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})
      erl_stub!(tmp, "exec sleep 30")

      started = System.monotonic_time(:millisecond)
      assert grab(indexer) == {:error, {:cardigann_grab, :parser_failed}}
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 500
      assert elapsed < 5_000
    end

    @tag :tmp_dir
    test "the deadline kills a running worker: its OS process is gone once the call returns",
         %{tmp_dir: tmp} do
      # 5 s, so the stub has written its pidfile before the deadline fires on a loaded host: a
      # 1.5 s deadline let the search's twin of this test fire first (#1845).
      grab_deadline!(5_000)
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})
      pidfile = Path.join(tmp, "worker.pid")

      erl_stub!(
        tmp,
        "echo $$ > '#{pidfile}.tmp' && mv '#{pidfile}.tmp' '#{pidfile}'\nexec sleep 30"
      )

      started = System.monotonic_time(:millisecond)
      assert grab(indexer) == {:error, {:cardigann_grab, :deadline}}
      assert System.monotonic_time(:millisecond) - started < 9_000

      {:ok, pid} = OsProcess.await_record(pidfile)
      assert OsProcess.dead?(pid |> String.trim() |> String.to_integer())
    end

    @tag :tmp_dir
    test "a worker that crashes on the details page is the parser-failed tag", %{tmp_dir: tmp} do
      indexer = t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_details(link: @magnet) end})

      # The positive control: the real worker reads the page.
      assert grab(indexer) == {:magnet, @magnet}

      erl_stub!(tmp, "exit 3")
      assert grab(indexer) == {:error, {:cardigann_grab, :parser_failed}}
    end
  end

  describe "the untrusted path" do
    test "a redirect to a private address is refused; one to a public address is followed" do
      indexer = t9!()
      test_pid = self()

      resolver = fn host ->
        send(test_pid, {:dns, host})

        case host do
          "inside.test" -> {:ok, [{10, 0, 0, 5}]}
          _public -> {:ok, [{93, 184, 216, 34}]}
        end
      end

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" -> {:redirect, 302, "https://inside.test/torrent/1"}
            "/torrent/2" -> {:redirect, 302, "https://mirror.test/torrent/2"}
          end
        end,
        "mirror.test" => fn _conn, _query -> torrent9_details(link: @magnet) end
      })

      assert grab(indexer, @details, resolver: resolver) == {:error, :forbidden_address}
      assert_received {:dns, "inside.test"}
      refute Enum.any?(requests(), &(elem(&1, 0) == "inside.test"))

      assert grab(indexer, "https://t9.test/torrent/2", resolver: resolver) == {:magnet, @magnet}
    end

    test "five redirects are followed and a sixth is refused" do
      indexer = t9!()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/r/" <> n ->
              n = String.to_integer(n)
              if n > 0, do: {:redirect, 302, "/r/#{n - 1}"}, else: torrent9_details(link: @magnet)
          end
        end
      })

      assert grab(indexer, "https://t9.test/r/5") == {:magnet, @magnet}
      assert length(requests()) == 6

      assert grab(indexer, "https://t9.test/r/6") == {:error, :too_many_redirects}
      assert length(requests()) == 6
    end

    test "a link carrying a password to a host off the credential hosts is never sent" do
      indexer =
        t9!(&(&1 |> with_password() |> selectors([@link_selector])), %{"password" => "hunter2"})

      torrent = TorrentFixture.minimal()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" -> torrent9_details(link: "https://cdn.test/dl/x.torrent?k=hunter2")
            "/torrent/2" -> torrent9_details(link: "https://t9.test/dl/x.torrent?k=hunter2")
            "/dl/x.torrent" -> {200, torrent}
          end
        end,
        "cdn.test" => fn _conn, _query -> {200, torrent} end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      refute Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))
      assert GrabFailure.retry_class({:cardigann_grab, :secret_host}) == :capped

      # The positive control: the same link on the credential host is fetched.
      assert grab(indexer, "https://t9.test/torrent/2") == {:ok, torrent}
      assert {"t9.test", "/dl/x.torrent", %{"k" => "hunter2"}} in requests()
    end

    test "a download block that references a password sends no link off the credential hosts" do
      with_key = %{
        "selector" => "a.dl",
        "attribute" => "href",
        "filters" => [
          %{"name" => "append", "args" => "?k={{ .Config.password }}"} | @masked
        ]
      }

      indexer = t9!(&(&1 |> with_password() |> selectors([with_key])), %{"password" => "hunter2"})

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_details(link: "https://cdn.test/dl/x.torrent")
        end,
        "cdn.test" => fn _conn, _query -> {200, TorrentFixture.minimal()} end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      refute Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))
    end

    test "a credential host's cookie goes back to it alone; another host's is dropped; no Referer" do
      indexer = t9!(&selectors(&1, [@link_selector]))
      torrent = TorrentFixture.minimal()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" ->
              page_with_cookie(
                conn,
                "sid=abc; Path=/; HttpOnly",
                torrent9_details(link: "https://cdn.test/dl/x")
              )

            "/dl/x.torrent" ->
              {200, torrent}
          end
        end,
        # The other host sets a cookie, then sends the chain back to itself once before the
        # link: a cookie it kept would show on that second request.
        "cdn.test" => fn conn, _query ->
          next =
            if conn.request_path == "/dl/x",
              do: "https://cdn.test/dl/y",
              else: "https://t9.test/dl/x.torrent"

          conn
          |> Plug.Conn.put_resp_header("set-cookie", "cdn=1; Path=/")
          |> Plug.Conn.put_resp_header("location", next)
          |> Plug.Conn.send_resp(302, "")
        end
      })

      assert grab(indexer) == {:ok, torrent}
      [page, cdn, cdn_again, link] = sent()

      assert Enum.map([page, cdn, cdn_again, link], &{&1.host, &1.path}) == [
               {"t9.test", "/torrent/1"},
               {"cdn.test", "/dl/x"},
               {"cdn.test", "/dl/y"},
               {"t9.test", "/dl/x.torrent"}
             ]

      assert List.keyfind(page.headers, "cookie", 0) == nil
      assert List.keyfind(cdn.headers, "cookie", 0) == nil
      assert List.keyfind(cdn_again.headers, "cookie", 0) == nil
      assert List.keyfind(link.headers, "cookie", 0) == {"cookie", "sid=abc"}
      refute Enum.any?([page, cdn, cdn_again, link], &List.keymember?(&1.headers, "referer", 0))
    end
  end

  describe "the cookie jar" do
    test "keeps 32 names per origin, then drops a new name and still replaces a known one" do
      indexer = t9!(&selectors(&1, [@link_selector]))
      torrent = TorrentFixture.minimal()
      cookies = for i <- 1..33, do: {"set-cookie", "c#{i}=v; Path=/"}

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" ->
              conn
              |> Plug.Conn.prepend_resp_headers(cookies ++ [{"set-cookie", "c1=new"}])
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, torrent9_details(link: "/dl/x.torrent"))

            "/dl/x.torrent" ->
              {200, torrent}
          end
        end
      })

      assert grab(indexer) == {:ok, torrent}
      [_page, link] = sent()
      {"cookie", header} = List.keyfind(link.headers, "cookie", 0)
      pairs = String.split(header, "; ")

      assert length(pairs) == 32
      assert "c1=new" in pairs
      refute "c33=v" in pairs
    end

    test "drops a pair of 4 KiB or more, a blank name, a comma or a control character" do
      indexer = t9!(&selectors(&1, [@link_selector]))
      torrent = TorrentFixture.minimal()
      # 4 + 4,091 bytes fit under 4,096; 3 + 4,093 do not.
      fits = "fits=" <> String.duplicate("v", 4_091)
      too_big = "big=" <> String.duplicate("v", 4_093)

      cookies =
        for cookie <- [fits, too_big, " =blank", "comma=a,b", "ctl=a\x01b", "del=a\x7fb", "ok=1"],
            do: {"set-cookie", cookie <> "; Path=/"}

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" ->
              conn
              |> Plug.Conn.prepend_resp_headers(cookies)
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, torrent9_details(link: "/dl/x.torrent"))

            "/dl/x.torrent" ->
              {200, torrent}
          end
        end
      })

      assert grab(indexer) == {:ok, torrent}
      [_page, link] = sent()
      {"cookie", header} = List.keyfind(link.headers, "cookie", 0)

      assert header |> String.split("; ") |> Enum.sort() == Enum.sort([fits, "ok=1"])
    end
  end

  describe "what the answer records" do
    test "a 429 on the details page starts the indexer's limit backoff" do
      indexer = t9!()

      route(%{
        "t9.test" => fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "600")
          |> Plug.Conn.send_resp(429, "")
        end
      })

      assert {:error, {:indexer_limit, until}} = grab(indexer)
      assert %{backoff: :limit, backoff_until: ^until} = status(indexer)
      assert GrabFailure.retry_class({:indexer_limit, until}) == :limit
    end

    test "a 429 on the link a selector found starts the indexer's limit backoff" do
      indexer = t9!(&selectors(&1, [@link_selector]))

      route(%{
        "t9.test" => fn conn, _query ->
          if conn.request_path == "/torrent/1" do
            torrent9_details(link: "/dl/x.torrent")
          else
            conn
            |> Plug.Conn.put_resp_header("retry-after", "600")
            |> Plug.Conn.send_resp(429, "")
          end
        end
      })

      assert {:error, {:indexer_limit, until}} = grab(indexer)
      assert %{backoff: :limit, backoff_until: ^until} = status(indexer)
    end

    test "a redirect that would carry a password off the credential hosts is never followed" do
      indexer = t9!(&with_password/1, %{"password" => "hunter2"})

      route(%{
        "t9.test" => fn _conn, _query ->
          {:redirect, 302, "https://cdn.test/torrent/1?k=hunter2"}
        end,
        "cdn.test" => fn _conn, _query -> torrent9_details(link: @magnet) end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      refute Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))
    end

    test "a redirect whose Location is not UTF-8 is never followed while a secret is set" do
      b = fn definition -> %{with_password(definition) | "id" => "cindertestt9b"} end

      [indexer, control] =
        setup!(
          [{"t9.yml", torrent9_like(&with_password/1)}, {"t9b.yml", torrent9_like(b)}],
          [
            {"t9.yml", torrent9_base(), %{"password" => "hunter2"}},
            {"t9b.yml", torrent9_base(), %{}}
          ]
        )

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" -> {:redirect, 302, "https://cdn.test/torrent/1\xff?k=hunter2"}
            "/torrent/2" -> {:redirect, 302, "https://t9.test/torrent/caf\xe9"}
            _own_host -> torrent9_details(link: @magnet)
          end
        end,
        "cdn.test" => fn _conn, _query -> torrent9_details(link: @magnet) end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      refute Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))

      # The control: the same redirect from an indexer with no secret value set is followed.
      assert grab(control) == {:magnet, @magnet}
      assert Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))

      # One that stays on the credential host is followed while the secret is set.
      assert grab(indexer, "https://t9.test/torrent/2") == {:magnet, @magnet}
    end

    test "a lone non-UTF-8 byte before a capitalised password does not hide it from the check" do
      indexer = t9!(&with_password/1, %{"password" => "Hunter2"})

      route(%{
        # `String.downcase/1` leaves the character after a lone 0xC3 byte as it is.
        "t9.test" => fn _conn, _query -> {:redirect, 302, "https://cdn.test/\xc3Hunter2"} end,
        "cdn.test" => fn _conn, _query -> torrent9_details(link: @magnet) end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      refute Enum.any?(requests(), &(elem(&1, 0) == "cdn.test"))
    end

    test "a redirect to the credential host's login page is auth failed; on another host it is not" do
      indexer = t9!()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/torrent/1" -> {:redirect, 302, "https://t9.test/login"}
            "/torrent/2" -> {:redirect, 302, "https://elsewhere.test/login"}
          end
        end,
        "elsewhere.test" => fn _conn, _query ->
          torrent9_details(extra: ~s(<form><input type="password" name="p"></form>))
        end
      })

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert status(indexer).last_failure == :rejected_credentials
      refute Enum.any?(requests(), &(elem(&1, 1) == "/login"))

      Repo.delete_all(IndexerStatus)
      assert grab(indexer, "https://t9.test/torrent/2") == {:error, {:cardigann_grab, :no_link}}
      assert %{backoff: :none, last_failure: nil} = status(indexer)
    end

    test "a login page the credential host answers on the details link is auth failed" do
      indexer = t9!()

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_details(extra: ~s(<form><input type="password" name="p"></form>))
        end
      })

      assert grab(indexer) == {:error, :indexer_auth_failed}
    end

    test "no error or log line holds a password the link carried" do
      indexer = t9!(&with_password/1, %{"password" => "hunter2"})
      link = "https://t9.test/torrent/1?k=hunter2"

      route(%{
        "t9.test" => fn conn, _query ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "60")
          |> Plug.Conn.send_resp(429, "slow down, hunter2")
        end
      })

      {answer, log} = with_log(fn -> grab(indexer, link) end)
      assert {:error, {:indexer_limit, _until}} = answer
      # The positive control: the stub saw the password.
      assert [{"t9.test", "/torrent/1", %{"k" => "hunter2"}}] = requests()
      refute inspect(answer) =~ "hunter2"
      refute log =~ "hunter2"

      route(%{"t9.test" => fn _conn, _query -> {:transport, :econnrefused} end})
      {answer, log} = with_log(fn -> grab(indexer, link) end)
      assert {:error, _reason} = answer
      assert [{"t9.test", "/torrent/1", %{"k" => "hunter2"}}] = requests()
      refute inspect(answer) =~ "hunter2"
      refute log =~ "hunter2"
    end
  end
end
