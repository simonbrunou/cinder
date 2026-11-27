defmodule Cinder.Acquisition.Indexer.CardigannDownloadKeysTest do
  # The download keys of #1679 (`download.headers`, `before`, `infohash`, `method: post`,
  # `usebeforeresponse` and a download selector's `remove`), through the real
  # `Cinder.Acquisition.IndexerSource.Native` `fetch_download/3`, on Torrent9-shaped definitions
  # written for Cinder (`Cinder.CardigannFixtures`), behind the `Cinder.CardigannStub` plug. The
  # `before` and `infohash` blocks copy the shapes of v11's `arabafenice` (a POST thanks request),
  # `kinozal-magnet` (a GET `before` whose answer `infohash` reads), `magnetdownload` (`:root` on
  # a JSON answer) and `ebookbay` (`infohash` on the details page), at Prowlarr/Indexers
  # `56b20b19`.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase
  alias Cinder.Download.GrabFailure
  alias Cinder.TorrentFixture

  @now ~U[2026-11-26 12:00:00Z]
  @hash String.duplicate("ab", 20)
  @link "https://t9.test/torrent/1?id=7"
  @key "k3y-Synthetic+value"

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

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

  defp grab(indexer, link \\ @link), do: Native.fetch_download(link, nil, opts(indexer, []))

  defp t9!(edit, secrets \\ %{}) do
    [indexer] = setup!([{"t9.yml", torrent9_like(edit)}], [{"t9.yml", torrent9_base(), secrets}])
    indexer
  end

  defp download(definition, block), do: Map.put(definition, "download", block)

  defp with_setting(definition, name, type) do
    Map.update!(
      definition,
      "settings",
      &(&1 ++ [%{"name" => name, "type" => type, "label" => name}])
    )
  end

  # Every request the stub received so far, in order, with its method, headers and body.
  defp sent do
    receive do
      {:cardigann_request, host, path, query, headers} ->
        receive do
          {:cardigann_wire, ^host, method, ^path, _query_string, body} ->
            [
              %{
                host: host,
                method: method,
                path: path,
                query: query,
                headers: Map.new(headers),
                body: body
              }
              | sent()
            ]
        end
    after
      0 -> []
    end
  end

  defp torrent, do: TorrentFixture.minimal()

  @link_selector %{"selector" => "a.dl", "attribute" => "href"}

  # `arabafenice.yml`'s thanks request.
  @thanks %{
    "path" => "thanks.php",
    "method" => "post",
    "inputs" =>
      obj([{"infohash", "{{ .DownloadUri.Query.id }}"}, {"thanks", 1}, {"rndval", "14"}])
  }

  # `ebookbay.yml`'s infohash block, its title on a plain `h1`.
  @infohash %{
    "hash" => %{
      "selector" => ~S|td:contains("Info Hash:") ~ td|,
      "filters" => [%{"name" => "regexp", "args" => "([A-F|a-f|0-9]{40})"}]
    },
    "title" => %{
      "selector" => "h1",
      "filters" => [%{"name" => "trim"}, %{"name" => "validfilename"}]
    }
  }

  defp hash_page(hash, title) do
    """
    <html><body><h1> #{title} </h1>
    <table><tr><td>Info Hash:</td><td>#{hash}</td></tr></table></body></html>
    """
  end

  describe "download.headers and search.headers" do
    test "download.headers replace search.headers on each request to the own host, and no other" do
      indexer =
        t9!(
          fn definition ->
            definition
            |> with_setting("apikey", "password")
            |> put_in(["search", "headers"], %{"X-Search" => ["s"]})
            |> download(%{
              "selectors" => [@link_selector],
              "headers" => %{
                "Authorization" => ["Bearer {{ .Config.apikey }}"],
                "X-Two" => ["a", "b"]
              }
            })
          end,
          %{"apikey" => @key}
        )

      route(%{
        "t9.test" => fn _conn, _query ->
          ~s(<a class="dl" href="https://cdn.test/f.torrent">x</a>)
        end,
        "cdn.test" => fn _conn, _query -> {200, "application/x-bittorrent", torrent()} end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [details, cdn] = sent()
      assert details.headers["authorization"] == "Bearer " <> @key
      assert details.headers["x-two"] == "a"
      refute Map.has_key?(details.headers, "x-search")
      refute Map.has_key?(cdn.headers, "authorization")
      refute Map.has_key?(cdn.headers, "x-two")
    end

    test "with no download block, the link gets search.headers" do
      indexer =
        t9!(fn definition ->
          definition
          |> put_in(["search", "headers"], %{"X-Search" => ["s {{ .DownloadUri.Query.id }}"]})
          |> Map.delete("download")
        end)

      route(%{"t9.test" => fn _conn, _query -> {200, "application/x-bittorrent", torrent()} end})

      assert {:ok, _bytes} = grab(indexer)
      assert [%{headers: %{"x-search" => "s 7"}}] = sent()
    end

    test "a header that renders a byte outside printable ASCII is a capped grab failure, and sends nothing" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "selectors" => [@link_selector],
            "headers" => %{"X-Id" => ["{{ .DownloadUri.Query.id }}"]}
          })
        end)

      route(%{"t9.test" => fn _conn, _query -> flunk("sent") end})

      assert grab(indexer, "https://t9.test/torrent/1?id=%C3%A9") ==
               {:error, {:cardigann_grab, :bad_headers}}

      assert GrabFailure.retry_class({:cardigann_grab, :bad_headers}) == :capped
      assert sent() == []
    end
  end

  describe "download.before" do
    test "a POST before request sends its rendered inputs with the link as Referer, then the details page" do
      indexer =
        t9!(fn definition ->
          download(definition, %{"before" => @thanks, "selectors" => [@link_selector]})
        end)

      route(%{
        "t9.test" => fn
          %{request_path: "/thanks.php"}, _query -> "thanks"
          %{request_path: "/torrent/1"}, _query -> ~s(<a class="dl" href="/f.torrent">x</a>)
          %{request_path: "/f.torrent"}, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [before, details, file] = sent()

      assert %{method: "POST", path: "/thanks.php", body: "infohash=7&thanks=1&rndval=14"} =
               before

      assert before.headers["referer"] == @link
      assert before.headers["content-type"] == "application/x-www-form-urlencoded"
      assert %{method: "GET", path: "/torrent/1", body: ""} = details
      refute Map.has_key?(details.headers, "referer")
      assert %{method: "GET", path: "/f.torrent"} = file
    end

    test "a GET before request appends its inputs, and a key the link lacks renders blank" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "before" => %{
              "path" => "get_srv_details.php?x=1",
              "inputs" => %{"action" => "2", "id" => "{{ .DownloadUri.Query.id }}"}
            }
          })
        end)

      route(%{
        "t9.test" => fn
          %{request_path: "/get_srv_details.php"}, _query -> "ok"
          %{request_path: "/torrent/1"}, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer, "https://t9.test/torrent/1")
      assert [before, link] = sent()
      assert before.query == %{"x" => "1", "action" => "2", "id" => ""}
      assert before.method == "GET"
      assert link.path == "/torrent/1"
    end

    test "a Referer the definition sets goes on the details page and an own-host link" do
      indexer =
        t9!(fn definition ->
          definition
          |> put_in(["search", "headers"], %{"Referer" => ["https://t9.test/home"]})
          |> download(%{"selectors" => [@link_selector]})
        end)

      route(%{
        "t9.test" => fn
          %{request_path: "/torrent/1"}, _query -> ~s(<a class="dl" href="/f.torrent">f</a>)
          _conn, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [details, link] = sent()
      assert details.headers["referer"] == "https://t9.test/home"
      assert link.headers["referer"] == "https://t9.test/home"
    end

    test "the link off the own hosts sends no Referer, and the definition's own Referer never goes on it" do
      indexer =
        t9!(fn definition ->
          definition
          |> put_in(["search", "headers"], %{"Referer" => ["https://t9.test/home"]})
          |> download(%{"before" => %{"path" => "thanks.php"}})
        end)

      route(%{
        "t9.test" => fn _conn, _query -> "ok" end,
        "mirror.test" => fn _conn, _query -> {200, "application/x-bittorrent", torrent()} end
      })

      assert {:ok, _bytes} = grab(indexer, "https://mirror.test/f.torrent")
      assert [before, link] = sent()
      assert before.path == "/thanks.php"
      refute Map.has_key?(before.headers, "referer")
      refute Map.has_key?(link.headers, "referer")
    end

    test "a 500 on the before request is ignored, as Prowlarr ignores it" do
      indexer = t9!(&download(&1, %{"before" => %{"path" => "thanks.php"}}))

      route(%{
        "t9.test" => fn
          %{request_path: "/thanks.php"}, _query -> {500, "oops"}
          _conn, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
    end

    test "a 429 on the before request starts the indexer's limit backoff, and nothing follows" do
      indexer = t9!(&download(&1, %{"before" => %{"path" => "thanks.php"}}))

      route(%{
        "t9.test" => fn conn, _query ->
          conn |> Plug.Conn.put_resp_header("retry-after", "600") |> Plug.Conn.send_resp(429, "")
        end
      })

      assert {:error, {:indexer_limit, _until}} = grab(indexer)
      assert [%{path: "/thanks.php"}] = sent()
      assert %{backoff: :limit} = IndexerStatus.read([indexer])[indexer.id]
    end

    test "a login page on the before request is the indexer's rejected credentials" do
      indexer = t9!(&download(&1, %{"before" => %{"path" => "thanks.php"}}))
      route(%{"t9.test" => fn _conn, _query -> ~s(<form><input type="password"></form>) end})

      assert grab(indexer) == {:error, :indexer_auth_failed}
      assert [%{path: "/thanks.php"}] = sent()
    end

    test "a before request that redirects to a magnet, whose path does not render or is no web address is a capped failure" do
      magnet = "magnet:?xt=urn:btih:#{@hash}"

      redirecting = t9!(&download(&1, %{"before" => %{"path" => "thanks.php"}}))
      route(%{"t9.test" => fn _conn, _query -> {:redirect, 302, magnet} end})

      assert grab(redirecting) == {:error, {:cardigann_grab, :before_failed}}
      assert GrabFailure.retry_class({:cardigann_grab, :before_failed}) == :capped

      Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
      broken = t9!(&download(&1, %{"before" => %{"path" => "{{ .Config.missing }}"}}))
      _ = sent()

      assert grab(broken) == {:error, {:cardigann_grab, :before_failed}}
      assert sent() == []

      Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
      ftp = t9!(&download(&1, %{"before" => %{"path" => "ftp://t9.test/thanks.php"}}))

      assert grab(ftp) == {:error, {:cardigann_grab, :before_failed}}
      assert sent() == []
    end

    test "a before path past the template's output cap keeps its own tag and sends nothing" do
      long = String.duplicate("a", 70_000)
      indexer = t9!(&download(&1, %{"before" => %{"path" => long}}))
      _ = sent()

      assert grab(indexer) == {:error, {:cardigann_grab, :filter_output_cap}}
      assert sent() == []
    end

    test "a POST body holding a secret never follows a 307 to another host" do
      indexer =
        t9!(
          fn definition ->
            definition
            |> with_setting("password", "password")
            |> download(%{
              "before" => %{
                "path" => "login.php",
                "method" => "post",
                "inputs" => %{"password" => "{{ .Config.password }}"}
              }
            })
          end,
          %{"password" => "hunter2"}
        )

      route(%{
        "t9.test" => fn _conn, _query -> {:redirect, 307, "https://evil.test/collect"} end,
        "evil.test" => fn _conn, _query -> flunk("the body left the own hosts") end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      assert [%{host: "t9.test", body: "password=hunter2"}] = sent()
    end

    test "a POST body that holds a secret value read from the link never follows a 307 off-site" do
      # No template names the setting, so only the body's value check refuses the hop.
      indexer =
        t9!(
          fn definition ->
            definition
            |> with_setting("password", "password")
            |> download(%{
              "before" => %{
                "path" => "thanks.php",
                "method" => "post",
                "inputs" => %{"key" => "{{ .DownloadUri.Query.passkey }}"}
              }
            })
          end,
          %{"password" => "hunter2"}
        )

      route(%{
        "t9.test" => fn _conn, _query -> {:redirect, 307, "https://evil.test/collect"} end,
        "evil.test" => fn _conn, _query -> flunk("the body left the own hosts") end
      })

      assert grab(indexer, "https://t9.test/torrent/1?passkey=hunter2") ==
               {:error, {:cardigann_grab, :secret_host}}

      assert [%{host: "t9.test", body: "key=hunter2"}] = sent()
    end

    test "a before input that only references a secret refuses its 307 to another host" do
      # `hun-ter2` is a form the secret value check does not read, so only the block's
      # reference to the setting refuses the hop.
      masked = ~S|{{ re_replace .Config.password "hunter" "hun-ter" }}|

      indexer =
        t9!(
          fn definition ->
            definition
            |> with_setting("password", "password")
            |> download(%{
              "before" => %{
                "path" => "thanks.php",
                "method" => "post",
                "inputs" => %{"p" => masked}
              }
            })
          end,
          %{"password" => "hunter2"}
        )

      route(%{
        "t9.test" => fn _conn, _query -> {:redirect, 307, "https://evil.test/collect"} end,
        "evil.test" => fn _conn, _query -> flunk("the body left the own hosts") end
      })

      assert grab(indexer) == {:error, {:cardigann_grab, :secret_host}}
      assert [%{host: "t9.test", body: "p=hun-ter2"}] = sent()
    end
  end

  describe "download.infohash" do
    test "with usebeforeresponse, the before answer gives the magnet and the details page is not fetched" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "before" => %{
              "path" => "get_srv_details.php",
              "inputs" => %{"action" => "2", "id" => "{{ .DownloadUri.Query.id }}"}
            },
            "infohash" => Map.put(@infohash, "usebeforeresponse", "true")
          })
        end)

      route(%{"t9.test" => fn _conn, _query -> hash_page(@hash, "Dune: Part Two") end})

      assert grab(indexer) == {:magnet, "magnet:?xt=urn:btih:#{@hash}&dn=Dune%3A+Part+Two"}
      assert [%{path: "/get_srv_details.php", query: %{"action" => "2", "id" => "7"}}] = sent()
    end

    test "without usebeforeresponse the details page is fetched once, after the before request" do
      indexer =
        t9!(&download(&1, %{"before" => %{"path" => "thanks.php"}, "infohash" => @infohash}))

      route(%{
        "t9.test" => fn
          %{request_path: "/thanks.php"}, _query -> hash_page(String.duplicate("cd", 20), "No")
          _conn, _query -> hash_page(@hash, "Dune")
        end
      })

      assert grab(indexer) == {:magnet, "magnet:?xt=urn:btih:#{@hash}&dn=Dune"}
      assert [%{path: "/thanks.php"}, %{path: "/torrent/1"}] = sent()
    end

    test "magnetdownload's :root selectors read a JSON answer" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "before" => %{"path" => "api/json_info", "inputs" => %{"hashes" => "x"}},
            "infohash" => %{
              "usebeforeresponse" => "true",
              "hash" => %{
                "selector" => ":root",
                "filters" => [%{"name" => "regexp", "args" => "([A-F|a-f|0-9]{40})"}]
              },
              "title" => %{
                "selector" => ":root",
                "filters" => [
                  %{"name" => "regexp", "args" => ~S|name\". \"(.+?)\"|},
                  %{"name" => "validfilename"}
                ]
              }
            }
          })
        end)

      json = ~s({"#{@hash}": {"name": "Dune 2024"}})
      route(%{"t9.test" => fn _conn, _query -> {200, "application/json", json} end})

      assert grab(indexer) == {:magnet, "magnet:?xt=urn:btih:#{@hash}&dn=Dune+2024"}
    end

    test "a hash selector that matches nothing, or a value that is no info hash, is a capped failure" do
      indexer = t9!(&download(&1, %{"infohash" => @infohash}))

      for page <- [
            "<html><body><h1>Dune</h1></body></html>",
            hash_page("not-a-hash", "Dune"),
            hash_page(@hash, "") |> String.replace("<h1>  </h1>", "")
          ] do
        route(%{"t9.test" => fn _conn, _query -> page end})
        assert grab(indexer) == {:error, {:cardigann_grab, :infohash_not_found}}
      end

      assert GrabFailure.retry_class({:cardigann_grab, :infohash_not_found}) == :capped
    end

    test "a hash template or a title filter that hits a limit is the limit tag" do
      template = %{
        "selector" => ~S|td{{ re_replace .DownloadUri.Query.id "^(a+)+$" "" }}|,
        "filters" => []
      }

      capped = [%{"name" => "replace", "args" => ["D", String.duplicate("b", 70_000)]}]

      [by_template, by_filter] =
        setup!(
          [
            {"t9.yml",
             torrent9_like(&download(&1, %{"infohash" => %{@infohash | "hash" => template}}))},
            {"t9b.yml",
             torrent9_like(fn definition ->
               definition
               |> Map.put("id", "cindertestt9b")
               |> download(%{"infohash" => put_in(@infohash, ["title", "filters"], capped)})
             end)}
          ],
          [{"t9.yml", torrent9_base(), %{}}, {"t9b.yml", torrent9_base(), %{}}]
        )

      route(%{"t9.test" => fn _conn, _query -> hash_page(@hash, "Dune") end})

      backtracks = String.duplicate("a", 30) <> "!"

      assert grab(by_template, "https://t9.test/torrent/1?id=" <> backtracks) ==
               {:error, {:cardigann_grab, :regex_limit}}

      assert grab(by_filter) == {:error, {:cardigann_grab, :filter_output_cap}}
    end

    test "a login page reads as the indexer's rejected credentials before any selector" do
      indexer = t9!(&download(&1, %{"infohash" => @infohash}))

      route(%{
        "t9.test" => fn _conn, _query ->
          hash_page(@hash, "Dune") <> ~s(<input type="password">)
        end
      })

      assert grab(indexer) == {:error, :indexer_auth_failed}
    end
  end

  describe "download.method and usebeforeresponse on a selector" do
    test "method post sends the final request as a POST with an empty body" do
      indexer = t9!(&download(&1, %{"method" => "post", "selectors" => [@link_selector]}))

      route(%{
        "t9.test" => fn
          %{request_path: "/torrent/1"}, _query -> ~s(<a class="dl" href="/f.torrent">x</a>)
          _conn, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [%{method: "GET"}, %{method: "POST", path: "/f.torrent", body: ""}] = sent()
    end

    test "method post on a plain link posts the link itself" do
      indexer = t9!(&download(&1, %{"method" => "post"}))
      route(%{"t9.test" => fn _conn, _query -> {200, "application/x-bittorrent", torrent()} end})

      assert {:ok, _bytes} = grab(indexer)
      assert [%{method: "POST", path: "/torrent/1", body: ""}] = sent()
    end

    test "a selector with usebeforeresponse reads the before answer, and the details page is not fetched" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "before" => %{"path" => "thanks.php"},
            "selectors" => [Map.put(@link_selector, "usebeforeresponse", "true")]
          })
        end)

      route(%{
        "t9.test" => fn
          %{request_path: "/thanks.php"}, _query -> ~s(<a class="dl" href="/f.torrent">x</a>)
          _conn, _query -> {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [%{path: "/thanks.php"}, %{path: "/f.torrent"}] = sent()
    end

    test "a download selector that renders a secret is a capped failure, and the details page is read once" do
      # docs/agents/architecture.md "The parser worker is not a security boundary".
      indexer =
        t9!(
          fn definition ->
            definition
            |> with_setting("password", "password")
            |> download(%{
              "selectors" => [
                %{"selector" => "a[href*='{{ .Config.password }}']", "attribute" => "href"}
              ]
            })
          end,
          %{"password" => "hunter2"}
        )

      route(%{"t9.test" => fn _conn, _query -> ~s(<a class="dl" href="/f.torrent">f</a>) end})

      assert grab(indexer) == {:error, {:cardigann_grab, :definition_error}}
      assert GrabFailure.retry_class({:cardigann_grab, :definition_error}) == :capped
      assert [%{path: "/torrent/1"}] = sent()
    end

    test "a download selector's remove takes the matching descendants out before the value is read" do
      indexer =
        t9!(fn definition ->
          download(definition, %{
            "selectors" => [
              %{
                "selector" => "div.link",
                "remove" => "span",
                "filters" => [%{"name" => "trim"}]
              }
            ]
          })
        end)

      route(%{
        "t9.test" => fn
          %{request_path: "/torrent/1"}, _query ->
            ~s(<div class="link"><span>junk </span>/f.torrent</div>)

          _conn, _query ->
            {200, "application/x-bittorrent", torrent()}
        end
      })

      assert {:ok, _bytes} = grab(indexer)
      assert [%{path: "/torrent/1"}, %{path: "/f.torrent"}] = sent()
    end
  end
end
