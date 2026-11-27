defmodule Cinder.Indexers.Definitions.LoadCheckTest do
  # check/2 starts the real parser worker; selectors/1 reads the loaded copy only.
  use ExUnit.Case, async: true

  import Cinder.CardigannFixtures,
    only: [bytes: 1, nyaa_like: 0, torrent9_like: 0, torrent9_like: 1, without_download: 1]

  alias Cinder.Indexers.Definitions.LoadCheck
  alias Cinder.Indexers.Definitions.Loader

  # The smallest copy that loads with no unsupported feature, as in LoaderTest.
  @base %{
    "id" => "cindertest",
    "name" => "Cinder Test",
    "description" => "Written for Cinder's tests",
    "language" => "en-US",
    "type" => "public",
    "encoding" => "UTF-8",
    "links" => ["https://tracker.invalid/"],
    "settings" => [],
    "caps" => %{"modes" => %{"search" => ["q"]}},
    "search" => %{"rows" => %{"selector" => "tr"}, "fields" => %{"title" => %{"selector" => "a"}}}
  }

  defp yaml(map), do: Jason.encode!(map)

  defp block(name),
    do: %{"selector" => "#{name}", "remove" => "#{name}-x", "case" => %{"#{name}-k" => "1"}}

  defp field(name), do: %{"selector" => "#{name}"}

  # One distinct selector in every place the engine hands lexbor.
  @every_place %{
    "login" => %{
      "path" => "/l",
      "form" => "login-form",
      "test" => %{"path" => "/t", "selector" => "login-test"},
      "captcha" => %{"type" => "image", "selector" => "login-captcha", "input" => "c"},
      "selectors" => true,
      "inputs" => %{"login-key" => "{{ .Config.username }}"},
      "error" => [%{"selector" => "login-error", "message" => %{"selector" => "login-message"}}],
      "selectorinputs" => %{"i" => %{"selector" => "login-input"}},
      "getselectorinputs" => %{"g" => %{"selector" => "login-get"}}
    },
    "download" => %{
      "selectors" => [
        %{"selector" => "dl-one", "remove" => "dl-one-x"},
        %{"selector" => "dl-two"}
      ],
      "before" => %{"path" => "/b", "pathselector" => %{"selector" => "dl-before"}},
      "infohash" => %{
        "hash" => %{"selector" => "dl-hash", "remove" => "dl-hash-x"},
        "title" => %{"selector" => "dl-title"}
      }
    }
  }

  defp every_place(paths) do
    {:ok, definition} = Loader.load(yaml(every_place_copy(paths)))
    definition
  end

  defp every_place_copy(paths) do
    search = %{
      "paths" => paths,
      "error" => [%{"selector" => "s-error", "message" => %{"selector" => "s-message"}}],
      "rows" =>
        Map.merge(block("rows"), %{
          "dateheaders" => %{"selector" => "rows-date"},
          "count" => %{"selector" => "rows-count"}
        }),
      "fields" => %{"title" => block("f"), "size" => field("f-size")}
    }

    Map.put(Map.merge(@base, @every_place), "search", search)
  end

  # Every key path of the fixture, list indexes included, as LoaderTest walks @full.
  defp slot_paths(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [path ++ [key] | slot_paths(value, path ++ [key])] end)
  end

  defp slot_paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      at = path ++ [Access.at(index)]
      [at | slot_paths(value, at)]
    end)
  end

  defp slot_paths(_value, _path), do: []

  @login_and_download ~w(login-form login-test login-captcha login-key login-error login-message
                         login-input login-get dl-one dl-two dl-before dl-hash dl-title
                         dl-one-x dl-hash-x)

  describe "selectors/1" do
    test "collects every place of an HTML search, then login, then download" do
      selectors = LoadCheck.selectors(every_place([%{"path" => "/"}]))

      {search, rest} = Enum.split(selectors, length(selectors) - length(@login_and_download))
      assert rest == @login_and_download

      # `rows.count` is read on a JSON page only (#1679), so `rows-count` is not among them.
      assert Enum.sort(search) ==
               Enum.sort(~w(rows rows-x rows-k rows-date f f-x f-k f-size s-error
                            s-message))

      assert Enum.take(search, 4) == ~w(rows rows-x rows-k rows-date)
      assert Enum.take(search, -2) == ~w(s-error s-message)
    end

    test "a login.inputs key is a selector only with login.selectors on" do
      copy = put_in(every_place_copy([%{"path" => "/"}]), ["login", "selectors"], false)
      {:ok, definition} = Loader.load(yaml(copy))
      off = LoadCheck.selectors(definition)
      on = LoadCheck.selectors(every_place([%{"path" => "/"}]))

      assert "login-key" in on
      assert List.delete(on, "login-key") == off
    end

    test "skips the search places when every path answers JSON or XML" do
      paths = [
        %{"path" => "/a", "response" => %{"type" => "json"}},
        %{"path" => "/b", "response" => %{"type" => "xml"}}
      ]

      assert LoadCheck.selectors(every_place(paths)) == @login_and_download
    end

    test "keeps the search places when any path answers HTML" do
      for html <- [%{"path" => "/c"}, %{"path" => "/c", "response" => %{"type" => "html"}}] do
        paths = [%{"path" => "/a", "response" => %{"type" => "json"}}, html]
        assert "rows" in LoadCheck.selectors(every_place(paths)), inspect(html)
      end
    end

    # docs/agents/testing.md: a reader of untrusted input never raises. `check/2` hands each
    # selector to `Selector.compile/2`, which takes only a binary.
    test "answers only binaries and raises on none of seven value shapes in any slot" do
      copy = every_place_copy([%{"path" => "/"}])

      problems =
        for(
          path <- slot_paths(copy, []),
          value <- [nil, "x", ["x"], [nil], [%{}], %{}, %{"a" => nil}],
          do: {path, value}
        )
        |> Task.async_stream(fn {path, value} ->
          try do
            case Loader.load(yaml(put_in(copy, path, value))) do
              {:ok, definition} ->
                selectors = LoadCheck.selectors(definition)
                if Enum.all?(selectors, &is_binary/1), do: nil, else: {path, value, selectors}

              {:error, _reason} ->
                nil
            end
          rescue
            error -> {path, value, Exception.message(error)}
          end
        end)
        |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)

      assert problems == []
    end

    test "lists a selector used twice once" do
      {:ok, definition} =
        @base
        |> put_in(["search", "fields"], %{
          "a" => %{"selector" => "tr"},
          "b" => %{"selector" => "a"}
        })
        |> yaml()
        |> Loader.load()

      assert LoadCheck.selectors(definition) == ["tr", "a"]
    end
  end

  describe "the static pattern check" do
    defp fields_with(filters),
      do:
        put_in(@base, ["search", "fields"], %{
          "title" => %{"selector" => "a", "filters" => filters}
        })

    defp rx(name, pattern) when name == "regexp", do: %{"name" => name, "args" => pattern}
    defp rx(name, pattern), do: %{"name" => name, "args" => [pattern, "$1"]}

    # Hand-written copies shaped like the 31 v11 definitions whose 34 patterns do not compile as
    # written (Prowlarr/Indexers 56b20b19): where each pattern sits and the syntax it uses.
    @cyrillic "(\\([\\p{IsCyrillic}\\W]+\\))|(^[\\p{IsCyrillic}\\W\\d]+\\/ )|" <>
                "([\\p{IsCyrillic} \\-]+,+)|([\\p{IsCyrillic}]+)"
    @balancing "\\(((?>[^()]+|(?<o>)\\(|(?<-o>)\\))*(?(o)(?!)))(?<!\\bHONE)(?<=\\s*- [\\w]+)\\)$"

    defp v11_shapes do
      [
        {"rutor and 25 more", fields_with([rx("re_replace", @cyrillic)])},
        {"thepiratebay",
         put_in(@base, ["search", "keywordsfilters"], [
           rx("re_replace", "([\\p{IsCJKUnifiedIdeographs}\\W]+)")
         ])},
        {"keepfriends", fields_with([rx("regexp", "([\\u4e00-\\u9fff])")])},
        {"mikan",
         fields_with([rx("regexp", "(\\d{4}/\\d{1,2}/\\d{1,2}[\\s\\u00A0]+\\d{1,2}:\\d{2})")])},
        {"puntotorrent",
         fields_with([
           rx("re_replace", "(?i)T[\\s-_]?(\\d{1,2})(.*)\\[(\\d{1,2})[x|\\/|\\\\](\\d{1,2})\\]"),
           rx("re_replace", "(?i)T[\\s-_]?(\\d{1,2})\\b")
         ])},
        {"hawke-uno", fields_with([rx("re_replace", @balancing)])}
      ]
    end

    test "only the balancing-group copy among the v11 shapes stays not supported" do
      # Each list in full: the loader turns on `regexp`, `re_replace` and `keywordsfilters`
      # (#1671), so only the check's own code is left.
      expected = %{
        "rutor and 25 more" => [],
        "thepiratebay" => [],
        "keepfriends" => [],
        "mikan" => [],
        "puntotorrent" => [],
        "hawke-uno" => [regex: :dotnet_only]
      }

      for {name, copy} <- v11_shapes() do
        assert {:ok, definition} = LoadCheck.check(yaml(copy))
        assert {name, definition.unsupported} == {name, Map.fetch!(expected, name)}
      end
    end

    test "each v11 shape's pattern fails without the translation" do
      # The patterns as written: PCRE refuses \u, the .NET block names and [\s-_].
      for {name, copy} <- v11_shapes() do
        {:ok, definition} = Loader.load(yaml(copy))

        refused =
          Enum.reject(LoadCheck.patterns(definition), fn pattern ->
            match?({:ok, _}, Regex.compile(pattern, "u"))
          end)

        assert {name, refused != []} == {name, true}
      end
    end

    test "an unknown block name and a pattern that does not compile read as invalid" do
      for pattern <- ["\\p{IsFoo}", "(", "(?<n>a)", "\\C"] do
        copy = fields_with([rx("regexp", pattern)])

        assert {:ok, definition} = LoadCheck.check(yaml(copy))

        assert {pattern, definition.unsupported} ==
                 {pattern, [regex: :invalid]}
      end
    end

    test "reads every filter list but the row filters, each pattern once" do
      filters = [rx("regexp", "(a)"), rx("re_replace", "b"), %{"name" => "trim", "args" => "c"}]

      copy =
        @base
        |> put_in(["search", "fields"], %{"t" => %{"selector" => "a", "filters" => filters}})
        |> put_in(["search", "keywordsfilters"], [rx("re_replace", "k")])
        |> put_in(["search", "preprocessingfilters"], [rx("re_replace", "p")])
        |> put_in(["search", "rows", "filters"], [
          %{"name" => "andmatch", "args" => "r"},
          %{"name" => "regexp", "args" => "r"}
        ])
        |> put_in(["login"], %{
          "selectorinputs" => %{"i" => %{"selector" => "s", "filters" => [rx("regexp", "l")]}}
        })
        |> put_in(["download"], %{
          "selectors" => [%{"selector" => "d", "filters" => [rx("regexp", "(a)")]}]
        })

      {:ok, definition} = Loader.load(yaml(copy))
      assert Enum.sort(LoadCheck.patterns(definition)) == Enum.sort(~w|(a) b k p l|)
    end

    test "adds dotnet_only then invalid, once each, after the selector codes" do
      fields = %{
        "a" => %{"selector" => "td /* x */", "filters" => [rx("regexp", "(")]},
        "b" => %{"selector" => "a", "filters" => [rx("re_replace", @balancing)]},
        "c" => %{"selector" => "a", "filters" => [rx("regexp", "\\p{IsFoo}")]}
      }

      copy = put_in(@base, ["search", "fields"], fields)
      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy))

      assert unsupported == [
               {:selector, :comment},
               {:regex, :dotnet_only},
               {:regex, :invalid}
             ]
    end
  end

  describe "check/2" do
    test "lists every code it adds, in its order" do
      assert LoadCheck.codes() ==
               [:dateparse_layout] ++
                 Enum.map(
                   ~w(comment escape structure template result_template refused crash timeout memory
                    output_too_large)a,
                   &{:selector, &1}
                 ) ++
                 [
                   {:regex, :dotnet_only},
                   {:regex, :invalid},
                   {:json, :path},
                   {:xml_selector, :invalid},
                   {:certificates, :malformed}
                 ]
    end

    test "a copy whose optional date field goes through fuzzytime has no code" do
      # At Prowlarr/Indexers 56b20b19 `{:filter, "fuzzytime"}` was the only code of those two
      # files (#1802). Shaped like 1337x's `date_today` and mikan's `date_day`.
      copy =
        put_in(@base, ["search", "fields"], %{
          "title" => %{"selector" => "a"},
          "date_day" => %{
            "selector" => "td:nth-child(1)",
            "optional" => true,
            "filters" => [
              %{"name" => "replace", "args" => ["昨天", "Yesterday"]},
              %{"name" => "fuzzytime"}
            ]
          }
        })

      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(copy))
    end

    test "adds nothing to a copy whose selectors all pass" do
      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(@base))
      # Its login and download add the loader's codes, and its selectors none.
      bytes = yaml(every_place_copy([%{"path" => "/"}]))
      assert {:ok, %{unsupported: [_code | _more] = codes}} = Loader.load(bytes)
      assert {:ok, %{unsupported: ^codes}} = LoadCheck.check(bytes)
    end

    test "answers the loader's answer otherwise unchanged" do
      bytes = yaml(@base)
      assert LoadCheck.check(bytes) == Loader.load(bytes)
    end

    test "passes a copy that fails to load through as the loader answered" do
      bytes = yaml(Map.delete(@base, "id"))
      assert {:error, _reason} = Loader.load(bytes)
      assert LoadCheck.check(bytes) == Loader.load(bytes)
    end

    test "adds each selector problem once, after the loader's codes, in its order" do
      fields = %{
        "a" => %{"selector" => ~S|[id!="x"]|},
        "b" => %{"selector" => ~S|a[href*="{{ .Config.x }}"]|},
        "c" => %{"selector" => "td /* x */"},
        "d" => %{"selector" => ~S|img[src$=\"x\"]|},
        "e" => %{"selector" => "td:has()"},
        "f" => %{"selector" => "td /* y */"},
        "g" => %{"selector" => "td:has(b[border=1])"}
      }

      copy =
        @base
        |> put_in(["search", "fields"], fields)
        |> put_in(["encoding"], "koi8-r")

      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy))

      assert unsupported == [
               :encoding,
               {:selector, :comment},
               {:selector, :escape},
               {:selector, :structure},
               {:selector, :template},
               {:selector, :refused}
             ]
    end

    test "reads td:has(b[border=1]) as refused: its part runs before the whole" do
      copy = put_in(@base, ["search", "rows", "selector"], "td:has(b[border=1])")
      assert {:ok, %{unsupported: [{:selector, :refused}]}} = LoadCheck.check(yaml(copy))
    end

    test "reads [id!=\"x\"] alone as refused" do
      copy = put_in(@base, ["search", "rows", "selector"], ~S|[id!="x"]|)
      assert {:ok, %{unsupported: [{:selector, :refused}]}} = LoadCheck.check(yaml(copy))
    end

    test "starts no worker for a copy with no selector to check" do
      copy =
        put_in(@base, ["search", "paths"], [%{"path" => "/", "response" => %{"type" => "json"}}])

      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy), max_memory_bytes: 1)
      refute Enum.any?(unsupported, &match?({:selector, _code}, &1))
    end

    test "starts no worker when the gate refuses every selector" do
      copy = put_in(@base, ["search", "fields"], %{"a" => %{"selector" => "a /* x */"}})
      copy = put_in(copy, ["search", "rows", "selector"], "tr /* x */")

      assert {:ok, %{unsupported: [{:selector, :comment}]}} =
               LoadCheck.check(yaml(copy), max_memory_bytes: 1)
    end

    test "reads a worker failure as one code for the whole copy" do
      assert {:ok, %{unsupported: [{:selector, :memory}]}} =
               LoadCheck.check(yaml(@base), max_memory_bytes: 1)
    end

    test "drops the gate's codes of a copy whose worker fails" do
      copy = put_in(@base, ["search", "rows", "selector"], "td /* x */")
      assert {:ok, %{unsupported: [{:selector, :comment}]}} = LoadCheck.check(yaml(copy))

      assert {:ok, %{unsupported: [{:selector, :memory}]}} =
               LoadCheck.check(yaml(copy), max_memory_bytes: 1)
    end
  end

  # #1671: the features Nyaa.si and Torrent9 use, on definitions written for Cinder.
  describe "Cardigann slice (a)" do
    test "a Nyaa-shaped copy loads" do
      assert {:ok, %{unsupported: []}} =
               LoadCheck.check(bytes(nyaa_like()))
    end

    # #1672 runs the download block at grab time.
    test "a Torrent9-shaped copy with its download block loads" do
      assert {:ok, %{unsupported: [], download: %{selectors: [_, _]}}} =
               LoadCheck.check(bytes(torrent9_like()))
    end

    test "a download selector template renders under the grab's variables, a query key included" do
      selector = ~S|a[data-id="{{ .DownloadUri.Query.id }}"][href^="{{ .DownloadUri.Scheme }}"]|

      copy =
        put_in(@base, ["download"], %{"selectors" => [%{"selector" => selector}]})

      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(copy))

      # A search variable is not a grab variable, and a rendering lexbor refuses is refused.
      keywords = put_in(copy, ["download", "selectors"], [%{"selector" => "{{ .Keywords }}"}])
      assert {:ok, %{unsupported: [{:selector, :template}]}} = LoadCheck.check(yaml(keywords))

      refused =
        put_in(copy, ["download", "selectors"], [
          %{"selector" => "{{ if .DownloadUri.Query.id }}td:has(){{ else }}td{{ end }}"}
        ])

      assert {:ok, %{unsupported: [{:selector, :structure}]}} = LoadCheck.check(yaml(refused))
    end

    test "a download selector template that reads .Result reads as a template" do
      copy =
        put_in(@base, ["download"], %{"selectors" => [%{"selector" => "{{ .Result.title }}"}]})

      assert {:ok, %{unsupported: [{:selector, :template}]}} = LoadCheck.check(yaml(copy))
    end

    test "the Torrent9-shaped copy without its download block loads" do
      copy = torrent9_like(&without_download/1)
      assert {:ok, %{unsupported: []}} = LoadCheck.check(bytes(copy))
    end

    test "a selector template is checked as each rendering, a refused one read as refused" do
      copy =
        put_in(@base, ["search", "fields"], %{
          "a" => %{"selector" => "{{ if .Keywords }}td:has(){{ else }}td{{ end }}"}
        })

      assert {:ok, %{unsupported: [{:selector, :structure}]}} = LoadCheck.check(yaml(copy))
    end

    # #1679 plans a field selector that reads `.Result` in a later worker round on an HTML page.
    test "a field selector template that reads .Result is checked as it renders, and loads" do
      copy =
        put_in(@base, ["search", "fields"], %{
          "a" => %{"selector" => "td"},
          "b" => %{"selector" => "{{ if .Result.a }}td{{ else }}th{{ end }}"}
        })

      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(copy))

      # Each rendering reaches the gate: a broken one under `.Result.a` set reads its code.
      broken =
        put_in(
          copy,
          ["search", "fields", "b", "selector"],
          "{{ if .Result.a }}td[{{ else }}th{{ end }}"
        )

      assert {:ok, %{unsupported: [_code]}} = LoadCheck.check(yaml(broken))
    end

    test "a .Result selector keeps its code on the rows, past the round cap, or beside an XML path" do
      result = "{{ if .Result.a }}td{{ else }}th{{ end }}"

      on_rows =
        put_in(@base, ["search", "rows", "selector"], "{{ if .Result.a }}tr{{ else }}tr{{ end }}")

      # e reads d, d reads c, c reads b, b reads a: four rounds after the first.
      chain =
        put_in(@base, ["search", "fields"], %{
          "a" => %{"selector" => "td"},
          "b" => %{"selector" => result},
          "c" => %{"selector" => String.replace(result, ".Result.a", ".Result.b")},
          "d" => %{"selector" => String.replace(result, ".Result.a", ".Result.c")},
          "e" => %{"selector" => String.replace(result, ".Result.a", ".Result.d")}
        })

      three = update_in(chain, ["search", "fields"], &Map.delete(&1, "e"))

      # An HTML path beside an XML one: the XML path renders the selector once.
      xml =
        @base
        |> put_in(["search", "paths"], [
          %{"path" => "/"},
          %{"path" => "rss", "response" => %{"type" => "xml"}}
        ])
        |> put_in(["search", "fields"], %{
          "a" => %{"selector" => "td"},
          "b" => %{"selector" => result}
        })

      for copy <- [on_rows, chain, xml] do
        assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy))
        assert {:selector, :result_template} in unsupported
      end

      # The control: three rounds load.
      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(three))
    end

    test "a selector template that does not render reads as a template" do
      copy =
        put_in(@base, ["search", "fields"], %{"a" => %{"selector" => "{{ if .Keywords }}td"}})

      assert {:ok, %{unsupported: [{:selector, :template}]}} = LoadCheck.check(yaml(copy))
    end

    test "a static date layout the engine does not read reads not supported" do
      fields = %{
        "date" => %{
          "selector" => "td",
          "filters" => [%{"name" => "dateparse", "args" => "dd/MM/yyyy gg"}]
        }
      }

      assert {:ok, %{unsupported: [:dateparse_layout]}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], fields)))

      timeparse = put_in(fields, ["date", "filters"], [%{"name" => "timeparse", "args" => "gg"}])

      assert {:ok, %{unsupported: [:dateparse_layout]}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], timeparse)))

      ok = put_in(fields, ["date", "filters"], [%{"name" => "dateparse", "args" => "dd/MM/yyyy"}])

      assert {:ok, %{unsupported: []}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], ok)))
    end

    test "a regex that does not compile or holds a named group reads not supported, in a field or a keyword filter" do
      bad = %{"name" => "re_replace", "args" => ["(unclosed", "x"]}
      good = %{"name" => "re_replace", "args" => ["(closed)", "x"]}

      field = fn filter -> %{"title" => %{"selector" => "a", "filters" => [filter]}} end

      assert {:ok, %{unsupported: [{:regex, :invalid}]}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], field.(bad))))

      assert {:ok, %{unsupported: []}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], field.(good))))

      keywords =
        put_in(@base, ["search", "keywordsfilters"], [%{"name" => "regexp", "args" => "["}])

      assert {:ok, %{unsupported: [{:regex, :invalid}]}} = LoadCheck.check(yaml(keywords))

      named = %{"name" => "regexp", "args" => "(?<year>\\d{4})"}

      assert {:ok, %{unsupported: [{:regex, :invalid}]}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], field.(named))))
    end

    test "a regex or a date layout that holds {{ is checked as written, as the filters read it" do
      fields = %{
        "title" => %{
          "selector" => "a",
          "filters" => [%{"name" => "re_replace", "args" => ["{{ .Config.x }}(", "y"]}]
        },
        "date" => %{
          "selector" => "td",
          "filters" => [%{"name" => "dateparse", "args" => "{{ if .Config.x }}gg{{ end }}"}]
        }
      }

      assert {:ok, %{unsupported: [:dateparse_layout, {:regex, :invalid}]}} =
               LoadCheck.check(yaml(put_in(@base, ["search", "fields"], fields)))
    end
  end

  # #1678: the JSON paths, the XML selectors and the pinned certificates.
  describe "the JSON, XML and certificate checks" do
    defp json_copy(search_edit) do
      search = %{
        "paths" => [%{"path" => "/api", "response" => %{"type" => "json"}}],
        "rows" => %{"selector" => "data:not(hidden)", "attribute" => "attributes"},
        "fields" => %{"title" => %{"selector" => "name"}, "id" => %{"selector" => "..id"}}
      }

      Map.put(@base, "search", search_edit.(search))
    end

    defp xml_copy(search_edit) do
      search = %{
        "paths" => [%{"path" => "/rss", "response" => %{"type" => "xml"}}],
        "rows" => %{"selector" => "rss > channel > item"},
        "fields" => %{
          "title" => %{"selector" => "title"},
          "seeders" => %{"selector" => "[name=seeders]", "attribute" => "value"},
          "free" => %{
            "selector" => "description:contains(Only Upload)",
            "case" => %{"*" => "1"}
          }
        }
      }

      Map.put(@base, "search", search_edit.(search))
    end

    defp check_codes(copy) do
      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy))
      unsupported
    end

    test "a JSON copy whose paths and chains read adds no code" do
      assert check_codes(json_copy(& &1)) == []

      copy =
        json_copy(fn search ->
          search
          |> put_in(["rows", "count"], %{"selector" => "$.total"})
          |> put_in(["rows", "selector"], "{{ if .Keywords }}data{{ else }}$[0].data{{ end }}")
          |> put_in(["fields", "tags"], %{
            "selector" => "tags",
            "filters" => [%{"name" => "jsonjoinarray", "args" => ["$.v", ", "]}]
          })
        end)

      assert check_codes(copy) == []
    end

    test "copies using the features #1678 lifts, in windows-1251 and with certificates, read no code" do
      json =
        json_copy(fn search ->
          put_in(search, ["fields", "tags"], %{
            "selector" => "tags",
            "filters" => [%{"name" => "jsonjoinarray", "args" => ["$.v", ","]}]
          })
        end)

      copy =
        json
        |> Map.put("encoding", "windows-1251")
        |> Map.put("certificates", [String.duplicate("aB", 20)])

      assert check_codes(copy) == []
      assert check_codes(Map.put(xml_copy(& &1), "encoding", "windows-1251")) == []

      # One copy with a JSON path and an XML path: each selector reads as a JSON path and as an
      # XML selector.
      both = %{
        "paths" => [
          %{"path" => "/api", "response" => %{"type" => "json"}},
          %{"path" => "/rss", "response" => %{"type" => "xml"}}
        ],
        "rows" => %{"selector" => "item"},
        "fields" => %{
          "title" => %{"selector" => "title"},
          "tags" => %{
            "selector" => "tags",
            "filters" => [%{"name" => "jsonjoinarray", "args" => ["$.v", ","]}]
          }
        }
      }

      mixed =
        @base
        |> Map.put("search", both)
        |> Map.put("encoding", "windows-1251")
        |> Map.put("certificates", [String.duplicate("aB", 20)])

      assert check_codes(mixed) == []
    end

    test "a JSON path or chain the walker does not read is {:json, :path}" do
      for {where, edit} <- [
            {"rows selector", &put_in(&1, ["rows", "selector"], "data[*]")},
            {"rows filter", &put_in(&1, ["rows", "selector"], "data:first")},
            {"rows attribute", &put_in(&1, ["rows", "attribute"], "a..b")},
            {"rows count", &put_in(&1, ["rows", "count"], %{"selector" => "$..total"})},
            {"field", &put_in(&1, ["fields", "title"], %{"selector" => "names[-1]"})},
            {"field key", &put_in(&1, ["fields", "title"], %{"selector" => "a:has(b[*])"})},
            {"rendered selector",
             &put_in(&1, ["rows", "selector"], "{{ if .Keywords }}data[*]{{ else }}data{{ end }}")},
            {"template that does not render", &put_in(&1, ["rows", "selector"], "{{ .Nope ")},
            {"jsonjoinarray path",
             &put_in(&1, ["fields", "tags"], %{
               "selector" => "tags",
               "filters" => [%{"name" => "jsonjoinarray", "args" => ["v[*]", ","]}]
             })}
          ] do
        assert {where, check_codes(json_copy(edit))} == {where, [{:json, :path}]}
      end
    end

    test "a jsonjoinarray path is checked in an HTML copy too, and its selectors are not paths" do
      join = [%{"name" => "jsonjoinarray", "args" => ["v[*]", ","]}]
      copy = put_in(@base, ["search", "fields", "title", "filters"], join)
      assert check_codes(copy) == [{:json, :path}]

      # `tr` is no JSON chain problem and `data[*]` no HTML one: each reader checks its own.
      assert check_codes(put_in(@base, ["search", "rows", "selector"], "tr > td")) == []
    end

    test "an XML copy with v11's selector shapes adds no code" do
      assert check_codes(xml_copy(& &1)) == []

      rendered =
        xml_copy(
          &put_in(
            &1,
            ["rows", "selector"],
            "{{ if .Keywords }}item{{ else }}channel > item{{ end }}"
          )
        )

      assert check_codes(rendered) == []
    end

    test "an XML pseudo-class other than :contains names itself, and bad syntax is :invalid" do
      for {edit, code} <- [
            {&put_in(&1, ["rows", "selector"], "item:has(title)"), {:xml_selector, "has"}},
            {&put_in(&1, ["fields", "title"], %{"selector" => "title:nth-child(2)"}),
             {:xml_selector, "nth-child"}},
            {&put_in(&1, ["fields", "free", "case"], %{"b:empty" => "1"}),
             {:xml_selector, "empty"}},
            {&put_in(&1, ["fields", "title"], %{"selector" => "a:not(:has(b))"}),
             {:xml_selector, "not"}},
            {&put_in(&1, ["fields", "title"], %{"selector" => "t|title"}),
             {:xml_selector, :invalid}},
            {&put_in(&1, ["fields", "title"], %{"selector" => ~S|t\:title|}),
             {:xml_selector, :invalid}},
            {&put_in(
               &1,
               ["rows", "selector"],
               "{{ if .Keywords }}item:empty{{ else }}item{{ end }}"
             ), {:xml_selector, "empty"}},
            {&put_in(&1, ["rows", "selector"], "{{ .Nope "), {:xml_selector, :invalid}}
          ] do
        assert check_codes(xml_copy(edit)) == [code]
      end
    end

    test "each selector adds its first refusal, each code once, in the order found" do
      copy =
        xml_copy(fn search ->
          search
          |> put_in(["rows", "selector"], "item:has(a)")
          |> put_in(["fields", "title"], %{"selector" => "a:empty, c:has(d)"})
          |> put_in(["fields", "size"], %{"selector" => "size:has(e)"})
        end)

      assert check_codes(copy) == [{:xml_selector, "has"}, {:xml_selector, "empty"}]
    end

    test "a certificates entry that is not 40 hex digits is {:certificates, :malformed}" do
      good = ["0123456789abcdefABCDEF0123456789abcdef01"]
      assert check_codes(put_in(@base, ["certificates"], good)) == []

      for entry <- [
            String.duplicate("a", 39),
            String.duplicate("a", 41),
            String.duplicate("g", 40),
            "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67",
            "",
            nil
          ] do
        assert {entry, check_codes(put_in(@base, ["certificates"], good ++ [entry]))} ==
                 {entry, [{:certificates, :malformed}]}
      end
    end

    test "the three checks add their codes in their order, after the others" do
      copy =
        json_copy(&put_in(&1, ["rows", "selector"], "data[*]"))
        |> put_in(["certificates"], ["xx"])
        |> put_in(["search", "paths"], [
          %{"path" => "/api", "response" => %{"type" => "json"}},
          %{"path" => "/rss", "response" => %{"type" => "xml"}}
        ])

      assert check_codes(copy) == [
               {:json, :path},
               {:xml_selector, :invalid},
               {:certificates, :malformed}
             ]
    end

    # docs/agents/testing.md: a reader of untrusted input never raises. A JSON copy and an XML
    # copy fill every slot the three checks read, with a field `remove` in the XML one, and an HTML
    # copy holds a field selector that reads `.Result` (#1679); then each slot takes each of seven
    # value shapes in turn.
    test "raises on none of seven value shapes in any slot the three checks read" do
      json =
        @base
        |> Map.put("certificates", [String.duplicate("aB", 20)])
        |> Map.put("search", %{
          "paths" => [
            %{"path" => "/api", "response" => %{"type" => "json", "noResultsMessage" => "none"}}
          ],
          "rows" => %{
            "selector" => "{{ if .Keywords }}data{{ else }}$[0].data{{ end }}",
            "attribute" => "attributes",
            "multiple" => true,
            "missingAttributeEqualsNoResults" => true,
            "count" => %{"selector" => "$.total", "filters" => [%{"name" => "trim"}]}
          },
          "fields" => %{
            "title" => %{"selector" => "title"},
            "tags" => %{
              "selector" => "tags",
              "filters" => [%{"name" => "jsonjoinarray", "args" => ["$.v", ","]}]
            }
          }
        })

      xml =
        @base
        |> Map.put("certificates", [String.duplicate("aB", 20)])
        |> Map.put("search", %{
          "paths" => [%{"path" => "/rss", "response" => %{"type" => "xml"}}],
          "rows" => %{"selector" => "{{ if .Keywords }}item{{ else }}channel > item{{ end }}"},
          "fields" => %{
            "title" => %{"selector" => "title"},
            "seeders" => %{"selector" => "[name=seeders]", "attribute" => "value"},
            "free" => %{"selector" => "description:contains(Free)", "case" => %{"b" => "1"}},
            "size" => %{"selector" => "size", "remove" => "b"}
          }
        })

      html =
        Map.put(@base, "search", %{
          "paths" => [%{"path" => "/"}],
          "rows" => %{"selector" => "tr"},
          "fields" => %{
            "title" => %{"selector" => "td.t"},
            "_sel" => %{"selector" => "td.sel"},
            "size" => %{"selector" => "{{ .Result._sel }}"}
          }
        })

      assert {check_codes(json), check_codes(xml), check_codes(html)} == {[], [], []}

      problems =
        for(
          copy <- [json, xml, html],
          path <- slot_paths(copy, []),
          value <- [nil, "x", ["x"], [nil], [%{}], %{}, %{"a" => nil}],
          do: {copy, path, value}
        )
        |> Task.async_stream(
          fn {copy, path, value} ->
            try do
              case LoadCheck.check(yaml(put_in(copy, path, value))) do
                {:ok, %{unsupported: codes}} when is_list(codes) -> nil
                {:error, _reason} -> nil
                other -> {path, value, other}
              end
            rescue
              error -> {path, value, Exception.message(error)}
            end
          end,
          timeout: 60_000
        )
        |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)

      assert problems == []
    end
  end
end
