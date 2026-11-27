defmodule Cinder.CardigannFixtures do
  @moduledoc """
  Cardigann definitions and search pages written for Cinder's tests, under its licence (#1671;
  #1616 rule 14, #1624 point 1). `nyaa_like/1` is shaped like Nyaa.si's definition and
  `torrent9_like/1` like Torrent9's: the same kinds of keys in the same places, with every name,
  host, selector value and text written here. No upstream file or saved page is copied.

  Each definition is a map whose order-sensitive parts (`search.fields`, `case`) are
  `Jason.OrderedObject`s, so `bytes/1` writes them in file order; JSON is YAML to the loader.
  Each builder takes a function that edits the map before it is written.

  The pages are hand-written HTML: `nyaa_page/1` and `torrent9_page/1` take one map per row.

  #1678 adds `api_like/1`, a JSON API definition shaped like the UNIT3D trackers' (rows under
  `data`, each row's fields under `attributes`), with `api_page/1`, and `rss_like/1`, an XML
  feed definition shaped like the RSS trackers' (`rss > channel > item`, Torznab-style
  `[name=...]` attributes), with `rss_page/1`. Every key, value and name is written here.
  """

  import ExUnit.Assertions

  alias Cinder.DefinitionFixtures
  alias Cinder.Indexers.Definitions.LoadCheck

  @nyaa_base "https://nyaa.test/"
  @torrent9_base "https://t9.test/"
  @api_base "https://api.test/"
  @rss_base "https://rss.test/"

  @doc "The base URL the JSON API definition lists first."
  def api_base, do: @api_base

  @doc "The base URL the RSS definition lists first."
  def rss_base, do: @rss_base

  @doc "The base URL the Nyaa-shaped definition lists first."
  def nyaa_base, do: @nyaa_base

  @doc "The base URL the Torrent9-shaped definition lists first."
  def torrent9_base, do: @torrent9_base

  @doc "An ordered JSON object from a keyword-like list of `{key, value}` pairs."
  def obj(pairs), do: %Jason.OrderedObject{values: pairs}

  @doc "The bytes the loader reads for `definition`."
  def bytes(definition), do: Jason.encode!(definition)

  @doc """
  A definition shaped like Nyaa.si's: public, `requestDelay` 2, two GET paths on `/` with search
  inputs `f`, `c`, `s`, `o` from select settings, `q` from the keywords on the first path and the
  keywords with one leading zero cut on the second, a keyword filter, `categorymappings` that map
  `1_0` and `1_2` under both TV/Anime and Movies/Other, a checkbox that prefers magnets, and
  fields that read earlier fields through `.Result`.
  """
  def nyaa_like(edit \\ & &1) do
    %{
      "id" => "cindertestnyaa",
      "name" => "Cinder Test Nyaa",
      "description" => "An anime tracker shaped like Nyaa.si, written for Cinder's tests",
      "language" => "en-US",
      "type" => "public",
      "encoding" => "UTF-8",
      "requestDelay" => "2",
      "links" => [@nyaa_base],
      "legacylinks" => ["https://old-nyaa.test/"],
      "caps" => %{
        "categorymappings" => [
          %{"id" => "1_0", "cat" => "TV/Anime", "desc" => "Anime"},
          %{"id" => "1_2", "cat" => "TV/Anime", "desc" => "Anime, translated"},
          %{"id" => "1_0", "cat" => "Movies/Other", "desc" => "Anime"},
          %{"id" => "1_2", "cat" => "Movies/Other", "desc" => "Anime, translated"},
          %{"id" => "2_0", "cat" => "Audio", "desc" => "Audio"},
          %{"id" => "4_0", "cat" => "TV", "desc" => "Live action"}
        ],
        "modes" => %{
          "search" => ["q"],
          "tv-search" => ["q", "season", "ep"],
          "movie-search" => ["q"],
          "book-search" => ["q"]
        },
        "allowrawsearch" => "true"
      },
      "settings" => [
        %{
          "name" => "prefer_magnet_links",
          "type" => "checkbox",
          "label" => "Prefer magnet links",
          "default" => "true"
        },
        select("filter-id", "0", obj([{"0", "None"}, {"1", "No remakes"}])),
        select("cat-id", "0_0", obj([{"0_0", "All"}, {"1_0", "Anime"}])),
        select("sort", "id", obj([{"id", "created"}, {"seeders", "seeders"}])),
        select("type", "desc", obj([{"desc", "desc"}, {"asc", "asc"}]))
      ],
      "search" => %{
        "paths" => [
          %{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}])},
          %{
            "path" => "/",
            "inputs" =>
              obj([
                {"q",
                 ~S|{{ if .Keywords }}{{ re_replace .Keywords "\b0(\d)\b" "$1" }}{{ else }}{{ end }}|},
                {"p", "{{ if .Keywords }}{{ else }}2{{ end }}"}
              ])
          }
        ],
        "inputs" =>
          obj([
            {"f", "{{ .Config.filter-id }}"},
            {"c", "{{ .Config.cat-id }}"},
            {"s", "{{ .Config.sort }}"},
            {"o", "{{ .Config.type }}"}
          ]),
        "keywordsfilters" => [
          %{"name" => "re_replace", "args" => [~S"(?i) *\b(S0?1)\b", " $1"]}
        ],
        "rows" => %{"selector" => "tr.default,tr.success"},
        "fields" =>
          obj([
            {"category",
             %{
               "selector" => "td:nth-child(1) a",
               "attribute" => "href",
               "filters" => [%{"name" => "split", "args" => ["=", "-1"]}]
             }},
            {"title_default", %{"selector" => "td:nth-child(2) a:last-of-type"}},
            {"title",
             %{"text" => "{{ .Result.title_default }}", "filters" => [%{"name" => "trim"}]}},
            {"details", %{"selector" => "td:nth-child(2) a:last-of-type", "attribute" => "href"}},
            {"download_optional",
             %{
               "selector" => ~S|td:nth-child(3) a[href$=".torrent"]|,
               "attribute" => "href",
               "optional" => "true"
             }},
            {"download",
             %{
               "text" =>
                 "{{ if .Config.prefer_magnet_links }}{{ else }}{{ .Result.download_optional }}{{ end }}",
               "optional" => "true"
             }},
            {"magnet",
             %{"selector" => ~S|td:nth-child(3) a[href^="magnet:?"]|, "attribute" => "href"}},
            {"size", %{"selector" => "td:nth-child(4)"}},
            {"date",
             %{
               "selector" => "td:nth-child(5)",
               "filters" => [
                 %{"name" => "append", "args" => " -00:00"},
                 %{"name" => "dateparse", "args" => "yyyy-MM-dd HH:mm zzz"}
               ]
             }},
            {"seeders",
             %{"selector" => "td:nth-child(6)", "optional" => "true", "default" => "0"}},
            {"description", %{"selector" => "td:nth-child(2) a:last-of-type"}}
          ])
      }
    }
    |> edit.()
  end

  @doc """
  A definition shaped like Torrent9's: public, `followredirect` on, one GET path whose template
  picks a search page or the latest page, keyword filters that turn a season suffix into
  `season N` and spaces into `-`, the `andmatch` row filter, a `case` block, templated
  selectors that read `.Keywords`, an `info_flaresolverr` setting, `testlinktorrent` off and a
  `download` block, which `without_download/1` drops. Its two download selectors read a details
  page's magnet link, then a magnet quoted inside a `<script>` through a `regexp` filter.
  """
  def torrent9_like(edit \\ & &1) do
    %{
      "id" => "cindertestt9",
      "name" => "Cinder Test T9",
      "description" => "A general tracker shaped like Torrent9, written for Cinder's tests",
      "language" => "fr-FR",
      "type" => "public",
      "encoding" => "UTF-8",
      "followredirect" => "true",
      "links" => [@torrent9_base],
      "caps" => %{
        "categorymappings" => [
          %{"id" => "films", "cat" => "Movies", "desc" => "Movies"},
          %{"id" => "series", "cat" => "TV", "desc" => "TV"},
          %{"id" => "ebook", "cat" => "Books", "desc" => "Books"},
          %{"id" => "other", "cat" => "Other", "desc" => "Other"}
        ],
        "modes" => %{
          "search" => ["q"],
          "tv-search" => ["q", "season", "ep"],
          "movie-search" => ["q"],
          "book-search" => ["q"]
        },
        "allowrawsearch" => "true"
      },
      "settings" => [
        %{"name" => "info_flaresolverr", "type" => "info_flaresolverr"},
        %{
          "name" => "multilang",
          "type" => "checkbox",
          "label" => "Rename MULTi",
          "default" => "false"
        },
        select("multilanguage", "FRENCH", obj([{"FRENCH", "FRENCH"}, {"ENGLISH", "ENGLISH"}]))
      ],
      "testlinktorrent" => "false",
      "download" => %{
        "selectors" => [
          %{"selector" => ~S|a[href^="magnet:?"]|, "attribute" => "href"},
          %{
            "selector" => ~S|script:contains("magnet:?")|,
            "filters" => [%{"name" => "regexp", "args" => ~S|'(magnet:\?[^']+)'|}]
          }
        ]
      },
      "search" => %{
        "paths" => [
          %{
            "path" => "{{ if .Keywords }}search/{{ .Keywords }}.html{{ else }}latest/{{ end }}"
          }
        ],
        "keywordsfilters" => [
          %{"name" => "re_replace", "args" => [~S"(?i)(S0)(\d{1,2})$", "season $2"]},
          %{"name" => "replace", "args" => [" ", "-"]}
        ],
        "rows" => %{
          "selector" => "table.results > tbody > tr",
          "filters" => [%{"name" => "andmatch"}]
        },
        "fields" =>
          obj([
            {"category_optional",
             %{
               "selector" => "td:nth-child(1) i",
               "optional" => "true",
               "case" => obj([{"i.icon-film", "films"}, {"i.icon-tv", "series"}])
             }},
            {"category",
             %{
               "text" =>
                 "{{ if .Result.category_optional }}{{ .Result.category_optional }}{{ else }}other{{ end }}"
             }},
            {"title", %{"selector" => "td:nth-child(1) a"}},
            {"details", %{"selector" => "td:nth-child(1) a", "attribute" => "href"}},
            {"download", %{"selector" => "td:nth-child(1) a", "attribute" => "href"}},
            {"date",
             %{
               "selector" => ~S|td:nth-child(2):contains("/")|,
               "optional" => "true",
               "default" => "now",
               "filters" => [%{"name" => "dateparse", "args" => "dd/MM/yyyy"}]
             }},
            {"size",
             %{
               "selector" =>
                 "{{ if .Keywords }}td:nth-child(3){{ else }}td:nth-child(2){{ end }}",
               "filters" => [%{"name" => "re_replace", "args" => [~S"(\w)o", "$1B"]}]
             }},
            {"seeders",
             %{
               "selector" =>
                 "{{ if .Keywords }}td:nth-child(4){{ else }}td:nth-child(3){{ end }}",
               "optional" => "true",
               "default" => "0"
             }}
          ])
      }
    }
    |> edit.()
  end

  @doc """
  A JSON API definition shaped like the UNIT3D trackers': private, an `apikey` setting sent as
  the `api_token` input, one GET path answering JSON with a `noResultsMessage`, rows under
  `data` without hidden ones (`:not(attributes.hidden)`), each narrowed to its `attributes`,
  `rows.count` read from `meta.total`, a `..id` field read from the row before it was narrowed,
  an array field (`genres`), a `case` keyed on `True` and `False`, and a date written as
  Newtonsoft prints it and read with `dateparse`.
  """
  def api_like(edit \\ & &1) do
    %{
      "id" => "cindertestapi",
      "name" => "Cinder Test API",
      "description" => "A private tracker API shaped like UNIT3D's, written for Cinder's tests",
      "language" => "en-US",
      "type" => "private",
      "encoding" => "UTF-8",
      "links" => [@api_base],
      "caps" => %{
        "categorymappings" => [
          %{"id" => "1", "cat" => "Movies", "desc" => "Movies"},
          %{"id" => "2", "cat" => "TV", "desc" => "TV"}
        ],
        "modes" => %{"search" => ["q"], "tv-search" => ["q"], "movie-search" => ["q"]}
      },
      "settings" => [%{"name" => "apikey", "type" => "text", "label" => "API key"}],
      "search" => %{
        "paths" => [
          %{
            "path" => "api/torrents/filter",
            "response" => %{"type" => "json", "noResultsMessage" => ~S("data":[])}
          }
        ],
        "inputs" => obj([{"api_token", "{{ .Config.apikey }}"}, {"name", "{{ .Keywords }}"}]),
        "rows" => %{
          "selector" => "data:not(attributes.hidden)",
          "attribute" => "attributes",
          "count" => %{"selector" => "meta.total"}
        },
        "fields" =>
          obj([
            {"category", %{"selector" => "category_id"}},
            {"title", %{"selector" => "name"}},
            {"details", %{"selector" => "details_link"}},
            {"download", %{"selector" => "download_link"}},
            {"size", %{"selector" => "size"}},
            {"seeders", %{"selector" => "seeders"}},
            {"genres", %{"selector" => "genres", "optional" => "true"}},
            {"free",
             %{
               "selector" => "freeleech",
               "optional" => "true",
               "case" => obj([{"True", "1"}, {"False", "0"}])
             }},
            {"id", %{"selector" => "..id"}},
            {"date",
             %{
               "selector" => "created_at",
               "filters" => [
                 %{"name" => "append", "args" => " +00:00"},
                 %{"name" => "dateparse", "args" => "MM/dd/yyyy HH:mm:ss zzz"}
               ]
             }},
            {"description",
             %{"text" => "{{ .Result.genres }} {{ .Result.free }} {{ .Result.id }}"}}
          ])
      }
    }
    |> edit.()
  end

  @doc """
  A search answer of the API-shaped definition. Each row map takes `:id`, `:name`, `:size` (a
  number), `:category` (a site id) and, optionally, `:hidden`, `:freeleech` (a boolean),
  `:genres` (a list), `:seeders` and `:created_at` (ISO 8601 text). `meta.total` is the row
  count unless `:total` is given.
  """
  def api_page(rows, opts \\ []) do
    data =
      Enum.map(rows, fn row ->
        attributes =
          [
            {"name", row.name},
            {"size", row.size},
            {"category_id", row.category},
            {"details_link", "#{@api_base}torrents/#{row.id}"},
            {"download_link", "#{@api_base}torrent/download/#{row.id}.abc"},
            {"seeders", Map.get(row, :seeders, 3)},
            {"genres", Map.get(row, :genres, [])},
            {"freeleech", Map.get(row, :freeleech, false)},
            {"created_at", Map.get(row, :created_at, "2026-11-25T10:30:00.000000Z")}
          ] ++ if(row[:hidden], do: [{"hidden", true}], else: [])

        obj([{"type", "torrent"}, {"id", row.id}, {"attributes", obj(attributes)}])
      end)

    total = Keyword.get(opts, :total, length(rows))
    Jason.encode!(obj([{"data", data}, {"meta", obj([{"total", total}])}]))
  end

  @doc """
  An XML feed definition shaped like the RSS trackers': public, one GET path answering XML,
  rows `rss > channel > item`, fields read from `title`, `link`, `pubDate` (through
  `dateparse`, as most RSS definitions read it), the `enclosure`'s
  `url` and `length`, and Torznab-style `[name=seeders]` and `[name=category]` attributes'
  `value`, and a `case` keyed on a `:contains` selector.
  """
  def rss_like(edit \\ & &1) do
    %{
      "id" => "cindertestrss",
      "name" => "Cinder Test RSS",
      "description" => "A public RSS feed tracker, written for Cinder's tests",
      "language" => "en-US",
      "type" => "public",
      "encoding" => "UTF-8",
      "links" => [@rss_base],
      "caps" => %{
        "categorymappings" => [
          %{"id" => "2000", "cat" => "Movies", "desc" => "Movies"},
          %{"id" => "5000", "cat" => "TV", "desc" => "TV"}
        ],
        "modes" => %{"search" => ["q"], "tv-search" => ["q"], "movie-search" => ["q"]}
      },
      "settings" => [],
      "search" => %{
        "paths" => [%{"path" => "rss", "response" => %{"type" => "xml"}}],
        "inputs" => obj([{"q", "{{ .Keywords }}"}]),
        "rows" => %{"selector" => "rss > channel > item"},
        "fields" =>
          obj([
            {"title", %{"selector" => "title"}},
            {"details", %{"selector" => "link"}},
            {"download", %{"selector" => "enclosure", "attribute" => "url"}},
            {"size", %{"selector" => "enclosure", "attribute" => "length"}},
            {"date",
             %{
               "selector" => "pubDate",
               "filters" => [%{"name" => "dateparse", "args" => "ddd, dd MMM yyyy HH:mm:ss zzz"}]
             }},
            {"seeders", %{"selector" => "[name=seeders]", "attribute" => "value"}},
            {"category", %{"selector" => "[name=category]", "attribute" => "value"}},
            {"free",
             %{
               "selector" => "description",
               "optional" => "true",
               "case" => obj([{~S|:contains("Freeleech")|, "1"}, {"*", "0"}])
             }}
          ])
      }
    }
    |> edit.()
  end

  @doc """
  A feed of the RSS-shaped definition. Each row map takes `:title`, `:id`, `:size` (bytes),
  `:category` and, optionally, `:seeders`, `:description` and `:date` (RFC 1123 text). `:prolog`
  writes an XML declaration first, and `:extra` any text right after it.
  """
  def rss_page(rows, opts \\ []) do
    items =
      Enum.map_join(rows, "\n", fn row ->
        """
        <item>
          <title>#{row.title}</title>
          <link>#{@rss_base}details/#{row.id}</link>
          <description>#{row[:description] || "Uploaded"}</description>
          <pubDate>#{row[:date] || "Wed, 25 Nov 2026 10:30:00 +0000"}</pubDate>
          <enclosure url="#{@rss_base}download/#{row.id}.torrent" length="#{row.size}" type="application/x-bittorrent"/>
          <torznab:attr name="seeders" value="#{row[:seeders] || 4}"/>
          <torznab:attr name="category" value="#{row.category}"/>
        </item>
        """
      end)

    """
    #{Keyword.get(opts, :prolog, "")}#{Keyword.get(opts, :extra, "")}<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
    <channel>
    <title>Cinder Test RSS</title>
    #{items}
    </channel>
    </rss>
    """
  end

  @doc """
  Mirrors each `{file_name, definition}` (maps as `nyaa_like/1` builds them) beside
  `Cinder.DefinitionFixtures`' fillers, checking each through the real
  `Cinder.Indexers.Definitions.LoadCheck` and the fillers through `DefinitionFixtures.check/1`,
  then creates one enabled Cardigann configured indexer per entry of `indexers`:
  `{file_name, base_url, secrets}` or `{file_name, base_url, secrets, overrides}`. Answers the
  rows in that order.
  """
  def setup!(files, indexers) do
    names = MapSet.new(files, &elem(&1, 0))

    given = MapSet.new(files, fn {_name, definition} -> bytes(definition) end)

    check = fn bytes ->
      if MapSet.member?(given, bytes),
        do: LoadCheck.check(bytes),
        else: DefinitionFixtures.check(bytes)
    end

    entries = for {name, definition} <- files, do: {"v11", name, bytes(definition)}
    assert {:ok, {:loaded, _}} = DefinitionFixtures.apply_files(entries, check: check)

    for entry <- indexers do
      {name, base_url, secrets, overrides} = with_overrides(entry)
      assert name in names
      {^name, definition} = List.keyfind(files, name, 0)

      DefinitionFixtures.cardigann!(
        bytes(definition),
        secrets,
        Map.merge(%{definition: name, base_url: base_url}, overrides)
      )
    end
  end

  defp with_overrides({name, base_url, secrets}), do: {name, base_url, secrets, %{}}
  defp with_overrides({_name, _base_url, _secrets, _overrides} = entry), do: entry

  @doc """
  Stubs `Cinder.CardigannStub` with `routes`, a map of host to answer function. The host is the
  request's `Host` header, the site's name: the URL holds the pinned address. Each function
  takes the conn and its query parameters and answers HTML (a 200 `text/html` page), `{status,
  body}`, `{status, content_type, body}`, `{:redirect, status, location}`,
  `{:transport, reason}` or a conn. Each request sends
  the test process `{:cardigann_request, host, path, query, headers}` first.
  """
  def route(routes) do
    test_pid = self()

    Req.Test.stub(Cinder.CardigannStub, fn conn ->
      conn = query_params(conn)
      [host | _] = Plug.Conn.get_req_header(conn, "host")

      send(
        test_pid,
        {:cardigann_request, host, conn.request_path, conn.query_params, conn.req_headers}
      )

      fun = Map.get(routes, host) || flunk("no route for #{host}")
      respond(conn, fun.(conn, conn.query_params))
    end)
  end

  # A query string that is not UTF-8, as a windows-1251 definition sends, reads as no parameters:
  # its test reads `conn.query_string`.
  defp query_params(conn) do
    Plug.Conn.fetch_query_params(conn)
  rescue
    Plug.Conn.InvalidQueryError -> %{conn | query_params: %{}}
  end

  defp respond(_conn, %Plug.Conn{} = conn), do: conn
  defp respond(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)

  defp respond(conn, {:redirect, status, location}) do
    conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(status, "")
  end

  defp respond(conn, {status, body}) when is_integer(status) do
    conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(status, body)
  end

  # A content type written as given, charset parameter included, as #1678's charset tests need.
  defp respond(conn, {status, content_type, body}) when is_integer(status) do
    conn
    |> Plug.Conn.put_resp_header("content-type", content_type)
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond(conn, body) when is_binary(body), do: respond(conn, {200, body})

  @doc "Every request the stub received so far, as `{host, path, query}`, in order."
  def requests do
    receive do
      {:cardigann_request, host, path, query, _headers} -> [{host, path, query} | requests()]
    after
      0 -> []
    end
  end

  @doc "Drops the definition's `download` block."
  def without_download(definition), do: Map.delete(definition, "download")

  defp select(name, default, options),
    do: %{
      "name" => name,
      "type" => "select",
      "label" => name,
      "default" => default,
      "options" => options
    }

  @doc """
  A search page of the Nyaa-shaped definition. Each row map takes `:title`, `:magnet`, `:size`
  (text), `:date` (`yyyy-MM-dd HH:mm`), `:cat` (a site id) and, optionally, `:torrent` (a path)
  and `:class` (`default` unless given).
  """
  def nyaa_page(rows) do
    body =
      Enum.map_join(rows, "\n", fn row ->
        torrent =
          if row[:torrent], do: ~s(<a href="#{row.torrent}"><i class="dl"></i></a> ), else: ""

        """
        <tr class="#{row[:class] || "default"}">
          <td><a href="/?c=#{row.cat}" title="Group"><img alt="group"></a></td>
          <td><a href="/view/#{row[:id] || 1}#comments" class="comments">2</a><a href="/view/#{row[:id] || 1}" title="#{row.title}">#{row.title}</a></td>
          <td>#{torrent}<a href="#{row.magnet}"><i class="magnet"></i></a></td>
          <td>#{row.size}</td>
          <td>#{row.date}</td>
          <td>#{row[:seeders] || 5}</td>
        </tr>
        """
      end)

    """
    <!doctype html><html><head><title>Results</title></head><body>
    <table class="torrent-list"><thead><tr><th>Category</th><th>Name</th></tr></thead>
    <tbody>
    #{body}
    </tbody></table></body></html>
    """
  end

  @doc """
  A search page of the Torrent9-shaped definition. Each row map takes `:title`, `:href` (the
  details path), `:size` (text), `:icon` (`film` or `tv`, or nil for none) and, optionally,
  `:date` (`dd/MM/yyyy`). `keywords?: false` writes the latest page's column order, which has no
  date column.
  """
  def torrent9_page(rows, keywords? \\ true) do
    body =
      Enum.map_join(rows, "\n", fn row ->
        icon = if row[:icon], do: ~s(<i class="icon-#{row.icon}"></i> ), else: ""
        date = if keywords?, do: "<td>#{row[:date] || "-"}</td>", else: ""

        """
        <tr>
          <td>#{icon}<a href="#{row.href}">#{row.title}</a></td>
          #{date}
          <td>#{row.size}</td>
          <td>#{row[:seeders] || 3}</td>
        </tr>
        """
      end)

    """
    <!doctype html><html><head><title>T9</title></head><body>
    <table class="results"><thead><tr><th>Name</th></tr></thead>
    <tbody>
    #{body}
    </tbody></table></body></html>
    """
  end

  @doc """
  A details page of the Torrent9-shaped definition. `:link` writes `<a class="dl">` whose `href`
  is the given value, `:script` a `<script>` that quotes the given magnet in single quotes, and
  `:extra` any HTML before them.
  """
  def torrent9_details(parts) do
    link = if parts[:link], do: ~s(<a class="dl" href="#{parts[:link]}">Get it</a>), else: ""

    script =
      if parts[:script],
        do: "<script>\nvar link = 'x';\nvar go = '#{parts[:script]}';\n</script>",
        else: ""

    """
    <!doctype html><html><head><title>T9 details</title></head><body>
    <h1>Details</h1>
    #{parts[:extra]}
    #{link}
    #{script}
    </body></html>
    """
  end
end
