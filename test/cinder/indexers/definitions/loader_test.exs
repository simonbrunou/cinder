defmodule Cinder.Indexers.Definitions.LoaderTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Filters
  alias Cinder.Indexers.Definitions.Loader

  # A definition written for Cinder, shaped like Nyaa.si's: no login, an HTML search over two
  # paths, settings, `categorymappings` with a `1_0` id, keyword filters, a `case` block and
  # field filters.
  @nyaa_like ~S"""
  ---
  id: cindertestnyaa
  name: Cinder Test Nyaa
  description: "A tracker shaped like Nyaa.si, written for Cinder's tests"
  language: en-US
  type: public
  encoding: UTF-8
  requestDelay: 2
  links:
    - https://tracker.invalid/

  caps:
    categorymappings:
      - {id: 1_0, cat: TV/Anime, desc: "Anime"}
      - {id: 1_0, cat: Movies/Other, desc: "Anime"}
      - {id: 2, cat: Audio, desc: "Audio"}
    modes:
      search: [q]
      tv-search: [q, season, ep]

  settings:
    - name: sort
      type: select
      label: Sort
      default: 0
      options:
        0: created
        1: seeders

  search:
    paths:
      - path: /
      - path: /
        inputs:
          p: 2
    inputs:
      q: "{{ .Keywords }}"
      s: "{{ .Config.sort }}"
    keywordsfilters:
      - name: re_replace
        args: ["S0?(\\d{1,2})", " $1 "]
    rows:
      selector: tr.default, tr.success
    fields:
      title:
        selector: td:nth-child(2) a:last-of-type
      category:
        selector: td:nth-child(1) a
        attribute: href
        filters:
          - name: replace
            args: ["/?c=", ""]
      download:
        selector: a[href$=".torrent"]
        attribute: href
      size:
        selector: td:nth-child(4)
      seeders:
        selector: td:nth-child(6)
      date:
        selector: td:nth-child(5)
        filters:
          - name: dateparse
            args: "yyyy-MM-dd HH:mm"
      downloadvolumefactor:
        case:
          "*": 0
  """

  # The smallest definition that loads: every required key, `settings: []` so that Prowlarr's
  # username and password settings stay out, and a search with no path, so no feature is in use.
  # Each table case below changes one slot of it.
  @base %{
    "id" => "cindertest",
    "name" => "Cinder Test",
    "description" => "Written for Cinder's tests",
    "language" => "en-US",
    "type" => "public",
    "encoding" => "UTF-8",
    "links" => ["https://tracker.invalid/"],
    "settings" => [],
    "caps" => %{
      "modes" => %{"search" => ["q"]},
      "categorymappings" => [%{"id" => "1", "cat" => "Movies"}]
    },
    "search" => %{"rows" => %{"selector" => "tr"}, "fields" => %{"title" => %{"selector" => "a"}}}
  }

  # JSON is YAML, so a map written as JSON loads; its order is not file order.
  defp yaml(map), do: Jason.encode!(map)

  defp load_with(path, value), do: Loader.load(yaml(put_in(@base, path, value)))

  defp unsupported(path, value) do
    assert {:ok, definition} = load_with(path, value)
    definition.unsupported
  end

  defp field(selector), do: %{"selector" => "a"} |> Map.merge(selector)
  defp filter(name), do: %{"name" => name, "args" => "x"}

  describe "a definition shaped like Nyaa.si" do
    # Every feature it uses is one Cardigann slice (a) builds (#1671).
    test "loads" do
      assert {:ok, definition} = Loader.load(@nyaa_like)

      assert definition.unsupported == []

      assert definition.id == "cindertestnyaa"
      assert definition.request_delay == 2.0

      assert [
               %{id: "1_0", cat: "TV/Anime"},
               %{id: "1_0", cat: "Movies/Other"},
               %{id: "2", cat: "Audio"}
             ] = definition.caps.categorymappings
    end
  end

  describe "the three answers" do
    test "a definition with no feature in use loads" do
      assert {:ok, %{unsupported: []}} = Loader.load(yaml(@base))
    end

    test "the features on are the filters, what slices (a) and (b), #1678 and #1679 build" do
      features = Loader.features()
      assert length(features) == 80
      assert length(Enum.uniq_by(features, &elem(&1, 0))) == 80

      filters =
        ~w(querystring timeparse dateparse regexp re_replace split replace trim prepend append
           tolower toupper base64decode base64encode urldecode urlencode htmldecode htmlencode
           timeago reltime validfilename diacritics jsonjoinarray hexdump strdump validate)

      assert for({code, true} <- features, do: code) ==
               [
                 :html_search,
                 :json_search,
                 :xml_search,
                 :search_post,
                 :search_path,
                 :search_path_categories,
                 :search_headers,
                 :raw_input,
                 :raw_search,
                 :allow_empty_inputs,
                 :keywords_filters,
                 :preprocessing_filters,
                 :search_error,
                 :selector_case,
                 :selector_remove,
                 {:row_filter, "andmatch"},
                 {:row_filter, "strdump"}
               ] ++
                 Enum.map(filters, &{:filter, &1}) ++
                 [
                   :download,
                   :download_before,
                   :download_infohash,
                   :download_post,
                   :download_headers,
                   :download_use_before_response,
                   :request_delay,
                   :follow_redirect,
                   :path_follow_redirect,
                   :certificates,
                   :category_default,
                   :tv_search_imdb,
                   {:setting, "info"},
                   {:setting, "text"},
                   {:setting, "password"},
                   {:setting, "checkbox"},
                   {:setting, "select"},
                   {:setting, "info_flaresolverr"}
                 ]

      assert filters -- Filters.supported() == []
    end

    test "cinder's application list holds yaml_elixir, so the release starts it" do
      assert :yaml_elixir in Application.spec(:cinder, :applications)
    end

    # Revision 2 is #1665's selector check (Cinder.Indexers.Definitions.LoadCheck), revision 3
    # #1677's filters and static pattern check, revision 4 Cardigann slice (a) (#1671), revision
    # 5 the grab's download block (#1672), revision 6 the JSON and XML answers, the charsets and
    # the pinned certificates (#1678), revision 7 the remaining search and download keys (#1679).
    test "fingerprint/0 declares schema version 12 and revision 7" do
      assert Loader.fingerprint() == %{schema_version: 12, revision: 7}
    end

    # #1679's acceptance: every key the slice lifts, in one HTML definition, loads with no code,
    # and the two `before` keys it leaves read their codes.
    test "a definition using every key #1679 lifts loads with no code" do
      selector = %{"selector" => "td", "remove" => "span", "filters" => [filter("trim")]}

      definition =
        @base
        |> put_in(["caps", "allowtvsearchimdb"], true)
        |> Map.put("search", %{
          "path" => "/legacy",
          "paths" => [
            %{
              "path" => "/q",
              "method" => "post",
              "followredirect" => true,
              "categories" => ["!", "1"],
              "inputs" => %{"$raw" => "{{ range .Categories }}c{{.}}=1&{{end}}"}
            }
          ],
          "allowEmptyInputs" => true,
          "inputs" => %{"$raw" => "q={{ .Keywords }}"},
          "headers" => %{"Authorization" => ["Bearer {{ .Config.apikey }}"]},
          "preprocessingfilters" => [filter("trim")],
          "error" => [%{"selector" => "div.e"}],
          "rows" => %{
            "selector" => "tr",
            "after" => 1,
            "dateheaders" => selector,
            "count" => %{"selector" => "span"}
          },
          "fields" => %{
            "title" => selector,
            "_staff" => %{"selector" => "b", "optional" => true},
            "size" => %{
              "selector" => "{{ if .Result._staff }}td:nth-child(5){{ else }}td{{ end }}"
            }
          }
        })
        |> Map.put("download", %{
          "method" => "post",
          "headers" => %{"Referer" => ["{{ .Config.sitelink }}"]},
          "before" => %{"path" => "/b", "method" => "post", "inputs" => %{"id" => "1"}},
          "selectors" => [Map.put(selector, "usebeforeresponse", true)],
          "infohash" => %{"hash" => selector, "title" => selector, "usebeforeresponse" => true}
        })

      assert {:ok, %{unsupported: []}} = Loader.load(yaml(definition))

      kept =
        update_in(definition, ["download", "before"], fn before ->
          Map.merge(before, %{"pathselector" => %{"selector" => "a"}, "queryseparator" => ";"})
        end)

      assert {:ok, %{unsupported: unsupported}} = Loader.load(yaml(kept))
      assert unsupported == [:download_before_pathselector, :download_before_queryseparator]
    end

    test "unknown values come first, then features in the list's order" do
      definition =
        @base
        |> put_in(["search", "paths"], [%{"path" => "/", "response" => %{"type" => "csv"}}])
        |> put_in(["type"], "secret")
        |> put_in(["encoding"], "koi8-r")
        |> put_in(["download"], %{
          "before" => %{"pathselector" => %{"selector" => "a"}, "queryseparator" => ";"}
        })

      assert {:ok, %{unsupported: unsupported}} = Loader.load(yaml(definition))

      assert unsupported == [
               {:unknown_value, :privacy_type},
               {:unknown_value, :response_type},
               :download_before_pathselector,
               :download_before_queryseparator,
               :encoding
             ]
    end

    test "a feature used twice is listed once" do
      fields = %{"title" => field(%{"filters" => [filter("fuzzytime"), filter("fuzzytime")]})}
      assert unsupported(["search", "fields"], fields) == [{:filter, "fuzzytime"}]
    end
  end

  describe "the size cap" do
    test "is 512 KiB" do
      assert Loader.max_bytes() == 524_288
    end

    test "a file one byte over the cap fails with :too_large, one at the cap loads" do
      text = yaml(@base) <> "\n#"
      at_cap = text <> String.duplicate("x", 524_288 - byte_size(text))

      assert byte_size(at_cap) == 524_288
      assert {:ok, %{unsupported: []}} = Loader.load(at_cap)
      assert Loader.load(at_cap <> "x") == {:error, :too_large}
    end

    test "the cap applies before parsing" do
      assert Loader.load(String.duplicate("&", 524_289)) == {:error, :too_large}
    end
  end

  # The same definition as @base, written as block YAML, so a case can append lines to it.
  @base_yaml """
  ---
  id: cindertest
  name: Cinder Test
  description: Written for Cinder's tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://tracker.invalid/
  caps:
    modes:
      search: [q]
    categorymappings:
      - {id: 1, cat: Movies}
  search:
    rows:
      selector: tr
    fields:
      title:
        selector: a
  """

  describe "refused YAML" do
    # The block base has no `settings`, so both read Prowlarr's two default settings.
    test "the block base loads like the JSON base" do
      assert Loader.load(@base_yaml) == Loader.load(yaml(Map.delete(@base, "settings")))
    end

    test "bytes that are not UTF-8 fail with :not_utf8" do
      assert Loader.load(@base_yaml <> <<"extra: ", 0xFF, "\n">>) == {:error, :not_utf8}
    end

    test "an anchor fails with :yaml_anchor" do
      assert Loader.load(@base_yaml <> "extra: &x [1, 2]\n") == {:error, :yaml_anchor}
    end

    test "an alias fails with :yaml_alias" do
      assert Loader.load(@base_yaml <> "extra: *x\n") == {:error, :yaml_alias}
    end

    test "an explicit tag on a scalar, on an empty value and on a collection fails with :yaml_tag" do
      for extra <- [
            "extra: !!binary aGk=\n",
            "extra: ! text\n",
            "extra: !!str\n",
            "extra: !\n",
            "extra: !foo\n",
            "extra: !!map {}\n",
            "extra: !!seq\n  - a\n"
          ] do
        assert {extra, Loader.load(@base_yaml <> extra)} == {extra, {:error, :yaml_tag}}
      end
    end

    test "a directive fails with :yaml_directive" do
      assert Loader.load("%YAML 1.2\n" <> @base_yaml) == {:error, :yaml_directive}
    end

    test "a second document fails with :yaml_second_document" do
      assert Loader.load(@base_yaml <> "---\nextra: 1\n") == {:error, :yaml_second_document}
      assert Loader.load(@base_yaml <> "...\n---\nextra: 1\n") == {:error, :yaml_second_document}
    end

    test "a key a mapping holds twice fails with :yaml_duplicate_key" do
      assert Loader.load(@base_yaml <> "extra: 1\nextra: 2\n") == {:error, :yaml_duplicate_key}

      nested =
        String.replace(@base_yaml, "    selector: tr\n", "    selector: tr\n    selector: td\n")

      assert Loader.load(nested) == {:error, :yaml_duplicate_key}
    end

    test "the same key in two mappings loads" do
      assert {:ok, _} = Loader.load(@base_yaml <> "extra:\n  a: {k: 1}\n  b: {k: 2}\n")
    end

    test "a & and a * inside a plain scalar and inside a quoted selector load" do
      text =
        @base_yaml
        |> String.replace(
          "  - https://tracker.invalid/\n",
          "  - https://tracker.invalid/?a=1&b=*\n"
        )
        |> String.replace("      selector: a\n", "      selector: 'a[href*=\"&x\"]'\n")

      assert {:ok, definition} = Loader.load(text)
      assert definition.links == ["https://tracker.invalid/?a=1&b=*"]
      assert [{"title", %{selector: ~S(a[href*="&x"])}}] = definition.search.fields
    end

    test "comment lines above --- load like the same file without them" do
      assert Loader.load("# a comment\n# another\n" <> @base_yaml) == Loader.load(@base_yaml)
    end

    test "a byte order mark before --- loads like the same file without it" do
      assert Loader.load(<<0xFEFF::utf8>> <> @base_yaml) == Loader.load(@base_yaml)
    end

    test "a collection used as a key in a record is ignored like any unknown key" do
      assert Loader.load(@base_yaml <> "? [zq]\n: id\n") == Loader.load(@base_yaml)
    end

    test "one --- line and a ... line load" do
      without = String.replace_prefix(@base_yaml, "---\n", "")
      assert Loader.load(without) == Loader.load(@base_yaml)
      assert Loader.load(@base_yaml <> "...\n") == Loader.load(@base_yaml)
    end
  end

  describe "YAML that fails to load" do
    test "YAML that does not parse fails with {:yaml_syntax, line}" do
      assert Loader.load("id: 1\n bad: 2\n") == {:error, {:yaml_syntax, 2}}
    end

    test "a top level that is not a mapping fails with :not_a_mapping" do
      for text <- ["", "# only a comment\n", "- a\n", "just text\n"] do
        assert {text, Loader.load(text)} == {text, {:error, :not_a_mapping}}
      end
    end
  end

  describe "file order" do
    test "search.fields and a case block keep file order" do
      text =
        String.replace(@base_yaml, "    title:\n      selector: a\n", """
            title:
              selector: a
            seeders:
              selector: b
            category:
              selector: c
              case:
                zz: 3
                mm: 2
                aa: 1
            download:
              selector: d
        """)

      assert {:ok, definition} = Loader.load(text)

      assert Enum.map(definition.search.fields, &elem(&1, 0)) ==
               ~w(title seeders category download)

      assert {"category", %{case: [{"zz", "3"}, {"mm", "2"}, {"aa", "1"}]}} =
               Enum.at(definition.search.fields, 2)
    end

    test "setting options and caps modes keep file order" do
      text =
        @base_yaml <>
          """
          settings:
            - name: s
              type: select
              options: {z: Z, b: B, m: M}
          """

      text =
        String.replace(
          text,
          "    search: [q]\n",
          "    search: [q]\n    tv-search: [q]\n    movie-search: [q]\n"
        )

      assert {:ok, definition} = Loader.load(text)
      assert [%{options: [{"z", "Z"}, {"b", "B"}, {"m", "M"}]}] = definition.settings
      assert Enum.map(definition.caps.modes, &elem(&1, 0)) == ~w(search tv-search movie-search)
    end
  end

  describe "slot typing" do
    test "string slots keep the text as written" do
      text =
        @base_yaml <>
          """
          requestDelay: 2.5
          settings:
            - name: n
              type: text
              default: 0
            - name: c
              type: checkbox
              default: true
            - name: f
              type: text
              default: 1.50
          """

      text =
        String.replace(
          text,
          "    - {id: 1, cat: Movies}\n",
          "    - {id: 1_0, cat: Movies}\n    - {id: 2, cat: TV}\n"
        )

      assert {:ok, definition} = Loader.load(text)
      assert [%{id: "1_0"}, %{id: "2"}] = definition.caps.categorymappings
      assert [%{default: "0"}, %{default: "true"}, %{default: "1.50"}] = definition.settings
      assert definition.request_delay == 2.5
    end

    test "a plain null spelling is nil, a quoted one is text" do
      text =
        @base_yaml <>
          """
          settings:
            - {name: a, type: text, default: }
            - {name: b, type: text, default: ~}
            - {name: c, type: text, default: null}
            - {name: d, type: text, default: NULL}
            - {name: e, type: text, default: ""}
            - {name: f, type: text, default: "null"}
            - {name: g, type: text, default: '~'}
          """

      assert {:ok, definition} = Loader.load(text)
      assert Enum.map(definition.settings, & &1.default) == [nil, nil, nil, nil, "", "null", "~"]
    end

    test "a boolean slot reads YamlDotNet's spellings in any case" do
      for {text, value} <- [
            {"true", true},
            {"Yes", true},
            {"ON", true},
            {"y", true},
            {"false", false},
            {"No", false},
            {"off", false},
            {"N", false}
          ] do
        assert {:ok, definition} =
                 load_with(["followredirect"], nil)
                 |> then(fn _ -> Loader.load(@base_yaml <> "followredirect: #{text}\n") end)

        assert {text, definition.followredirect} == {text, value}
      end
    end

    test "an absent or null slot takes the model's default" do
      assert {:ok, definition} = Loader.load(@base_yaml <> "testlinktorrent: ~\n")
      assert definition.followredirect == false
      assert definition.testlinktorrent == true
      assert definition.request_delay == nil
      assert definition.legacylinks == []
      assert definition.login == nil
      assert definition.search.rows.after == 0

      assert {:ok, definition} = load_with(["search", "paths"], [%{"path" => "/"}])

      assert [%{inheritinputs: true, queryseparator: "&", followredirect: false, inputs: []}] =
               definition.search.paths
    end

    test "numeric and boolean slots keep their type" do
      fields = %{"title" => field(%{"optional" => true})}
      assert {:ok, definition} = load_with(["search", "fields"], fields)
      assert [{"title", %{optional: true}}] = definition.search.fields

      assert {:ok, definition} = load_with(["search", "rows", "after"], 3)
      assert definition.search.rows.after == 3
    end

    test "filter args are text or a list of text" do
      filters = [
        %{"name" => "split", "args" => ["/", 0]},
        %{"name" => "trim", "args" => 2},
        %{"name" => "tolower"}
      ]

      assert {:ok, definition} =
               load_with(["search", "fields"], %{"title" => field(%{"filters" => filters})})

      assert [{"title", %{filters: [%{args: ["/", "0"]}, %{args: "2"}, %{args: nil}]}}] =
               definition.search.fields
    end

    test "a value of the wrong shape fails with {:wrong_type, path}" do
      cases = [
        {["followredirect"], "maybe", [:followredirect]},
        {["requestDelay"], "soon", [:request_delay]},
        {["requestDelay"], ".5", [:request_delay]},
        {["requestDelay"], "2s", [:request_delay]},
        {["links"], "https://tracker.invalid/", [:links]},
        {["caps"], ["q"], [:caps]},
        {["search", "rows", "after"], "1.5", [:search, :rows, :after]},
        {["search", "rows", "after"], "010", [:search, :rows, :after]},
        {["search", "fields"], %{"title" => "a"}, [:search, :fields, 0]},
        {["search", "fields"],
         %{"title" => field(%{"filters" => [%{"name" => "trim", "args" => %{"a" => "b"}}]})},
         [:search, :fields, 0, :filters, 0, :args]},
        {["settings"], [%{"name" => "a", "type" => "text", "default" => ["x"]}],
         [:settings, 0, :default]},
        {["search", "fields"],
         %{"title" => field(%{"filters" => [%{"name" => "trim", "args" => [["a"]]}]})},
         [:search, :fields, 0, :filters, 0, :args, 0]}
      ]

      for {path, value, reason_path} <- cases do
        assert {path, load_with(path, value)} == {path, {:error, {:wrong_type, reason_path}}}
      end
    end

    test "a collection used as a key of a free-form mapping fails with {:wrong_type, path}" do
      text =
        String.replace(
          @base_yaml,
          "    title:\n      selector: a\n",
          "    ? [a]\n    : {selector: a}\n"
        )

      assert Loader.load(text) == {:error, {:wrong_type, [:search, :fields, 0]}}
    end

    test "inputs: {} and no inputs give equal definitions" do
      with_inputs =
        @base
        |> put_in(["search", "inputs"], %{})
        |> put_in(["search", "paths"], [%{"path" => "/", "inputs" => %{}}])

      without = put_in(@base, ["search", "paths"], [%{"path" => "/"}])
      assert {:ok, a} = Loader.load(yaml(with_inputs))
      assert {:ok, b} = Loader.load(yaml(without))
      assert a == b
    end

    test "an unknown top-level key and an unknown key inside search are ignored" do
      text =
        String.replace(
          @base_yaml,
          "search:\n",
          "zq_unknown_root: 1\nsearch:\n  zq_unknown_search: [1]\n"
        )

      assert Loader.load(text) == Loader.load(@base_yaml)
    end

    test "the parsed definition holds no :file or :path key" do
      assert {:ok, definition} = Loader.load(@nyaa_like)
      refute Map.has_key?(definition, :file)
      refute Map.has_key?(definition, :path)
    end
  end

  describe "required keys" do
    @root_required ~w(id name description language type encoding links caps search)

    test "each required root key, removed alone, fails with {:missing_key, path}" do
      for key <- @root_required do
        atom = String.to_existing_atom(key)

        assert {key, Loader.load(yaml(Map.delete(@base, key)))} ==
                 {key, {:error, {:missing_key, [atom]}}}
      end
    end

    test "a required key holding null fails like a missing one" do
      assert Loader.load(@base_yaml |> String.replace("encoding: UTF-8\n", "encoding:\n")) ==
               {:error, {:missing_key, [:encoding]}}
    end

    test "caps.modes, search.rows, search.fields and a setting's name and type are required" do
      assert load_with(["caps"], Map.delete(@base["caps"], "modes")) ==
               {:error, {:missing_key, [:caps, :modes]}}

      assert load_with(["search"], Map.delete(@base["search"], "rows")) ==
               {:error, {:missing_key, [:search, :rows]}}

      assert load_with(["search"], Map.delete(@base["search"], "fields")) ==
               {:error, {:missing_key, [:search, :fields]}}

      assert load_with(["settings"], [%{"type" => "text"}]) ==
               {:error, {:missing_key, [:settings, 0, :name]}}

      assert load_with(["settings"], [%{"name" => "a", "type" => "text"}, %{"name" => "b"}]) ==
               {:error, {:missing_key, [:settings, 1, :type]}}
    end
  end

  describe "unknown values in fixed-value slots" do
    test "each reads as not supported with {:unknown_value, slot}" do
      json = %{"type" => "json"}

      cases = [
        {["type"], "secret", [{:unknown_value, :privacy_type}]},
        {["caps", "modes"], %{"search" => ["q"], "anime-search" => ["q"]},
         [{:unknown_value, :mode}]},
        {["caps", "modes"], %{"search" => ["q"], "tv-search" => ["q", "author"]},
         [{:unknown_value, :mode_parameter}]},
        {["caps", "categorymappings"], [%{"id" => "1", "cat" => "Movies/8K"}],
         [{:unknown_value, :category}]},
        {["caps", "categorymappings"], [%{"id" => "1"}], [{:unknown_value, :category}]},
        {["caps", "categories"], %{"1" => "Films"}, [{:unknown_value, :category}]},
        {["settings"], [%{"name" => "a", "type" => "slider"}], [{:unknown_value, :setting_type}]},
        {["login"], %{"method" => "magic"}, [{:unknown_value, :login_method}]},
        {["login"], %{"method" => "form", "captcha" => %{"type" => "audio"}},
         [{:unknown_value, :captcha_type}, {:login, "form"}, :login_captcha]},
        {["login"], %{"method" => "form", "captcha" => %{"selector" => "img"}},
         [{:unknown_value, :captcha_type}, {:login, "form"}, :login_captcha]},
        {["search", "paths"], [%{"path" => "/", "response" => %{"type" => "csv"}}],
         [{:unknown_value, :response_type}]},
        {["search", "paths"], [%{"path" => "/", "response" => %{}}],
         [{:unknown_value, :response_type}]},
        {["search", "rows", "filters"], [filter("anymatch")], [{:unknown_value, :row_filter}]},
        {["search", "rows", "filters"], [%{"args" => "x"}], [{:unknown_value, :row_filter}]},
        {["search", "fields"], %{"title" => field(%{"filters" => [filter("rot13")]})},
         [{:unknown_value, :filter}]},
        {["search", "fields"], %{"title" => field(%{"filters" => [%{"args" => "x"}]})},
         [{:unknown_value, :filter}]},
        {["search", "keywordsfilters"], [filter("rot13")], [{:unknown_value, :filter}]},
        {["search", "paths"], [%{"path" => "/", "response" => json}], []},
        {["search", "paths"], [%{"path" => "/", "response" => %{"type" => "xml"}}], []}
      ]

      for {path, value, expected} <- cases do
        assert {path, value, unsupported(path, value)} == {path, value, expected}
      end
    end

    test "base64decode and base64encode, new in v12, read as known filters the engine runs" do
      for name <- ~w(base64decode base64encode) do
        fields = %{"title" => field(%{"filters" => [filter(name)]})}
        assert {name, unsupported(["search", "fields"], fields)} == {name, []}
      end
    end
  end

  describe "the defaults Prowlarr fills in after reading the file" do
    test "no settings, or a null settings, reads Prowlarr's username and password settings" do
      for settings <- [:absent, nil] do
        base =
          if settings == :absent,
            do: Map.delete(@base, "settings"),
            else: put_in(@base, ["settings"], nil)

        assert {:ok, definition} = Loader.load(yaml(base))

        assert [
                 %{name: "username", label: "Username", type: "text", default: nil, options: []},
                 %{name: "password", label: "Password", type: "password", default: nil}
               ] = definition.settings

        assert definition.unsupported == []
      end
    end

    test "settings: [] reads no setting" do
      assert {:ok, %{settings: [], unsupported: []}} = Loader.load(yaml(@base))
    end

    test "a login with no method reads as a form login" do
      for login <- [%{"path" => "/login"}, %{"path" => "/login", "method" => nil}, %{}] do
        assert {:ok, definition} = load_with(["login"], login)
        assert definition.login.method == "form"
        assert definition.unsupported == [{:login, "form"}]
      end
    end

    test "a null login stays absent" do
      assert {:ok, %{login: nil, unsupported: []}} = load_with(["login"], nil)
    end

    test "search.path runs after every search.paths entry, inheriting the inputs" do
      search =
        @base["search"]
        |> Map.put("path", "/html")
        |> Map.put("paths", [%{"path" => "/api", "response" => %{"type" => "json"}}])

      assert {:ok, definition} = load_with(["search"], search)

      assert [
               %{path: "/api", response: %{type: "json"}},
               %{path: "/html", response: nil, inheritinputs: true, method: nil, inputs: []}
             ] = definition.search.paths

      assert definition.unsupported == []
    end

    test "search.path alone is the one search path" do
      assert {:ok, definition} = load_with(["search", "path"], "/html")

      assert [%{path: "/html", inheritinputs: true, queryseparator: "&", categories: []}] =
               definition.search.paths

      assert definition.unsupported == []
    end
  end

  describe "a definition with every recognised key" do
    # Every key of every record, each with a value other than its default.
    @filter_full %{"name" => "trim", "args" => ["a", "b"]}
    @selector_full %{
      "selector" => "a",
      "attribute" => "href",
      "optional" => true,
      "default" => "d",
      "case" => %{"x" => "y"},
      "remove" => "r",
      "text" => "t",
      "filters" => [@filter_full]
    }
    @selector_field_full %{
      "selector" => "a",
      "attribute" => "href",
      "remove" => "b",
      "usebeforeresponse" => true,
      "filters" => [@filter_full]
    }
    @error_full %{"path" => "/e", "selector" => "e", "message" => @selector_full}
    @full %{
      "id" => "cinderfull",
      "replaces" => ["old"],
      "name" => "Full",
      "description" => "Every key",
      "language" => "en-US",
      "type" => "private",
      "encoding" => "windows-1251",
      "followredirect" => true,
      "testlinktorrent" => false,
      "requestDelay" => 2.5,
      "links" => ["https://a.invalid/"],
      "legacylinks" => ["https://b.invalid/"],
      "certificates" => ["ab12"],
      "caps" => %{
        "categories" => %{"1" => "Movies"},
        "categorymappings" => [%{"id" => "2", "cat" => "TV", "desc" => "T", "default" => true}],
        "modes" => %{"search" => ["q"]},
        "allowrawsearch" => true,
        "allowtvsearchimdb" => true
      },
      "settings" => [
        %{
          "name" => "s",
          "label" => "S",
          "type" => "select",
          "default" => "1",
          "options" => %{"1" => "one"},
          "defaults" => ["1"]
        }
      ],
      "login" => %{
        "method" => "form",
        "cookies" => ["c=1"],
        "path" => "/l",
        "submitpath" => "/s",
        "form" => "f",
        "captcha" => %{"type" => "image", "selector" => "img", "input" => "cap"},
        "inputs" => %{"u" => "x"},
        "selectors" => true,
        "selectorinputs" => %{"t" => @selector_full},
        "getselectorinputs" => %{"g" => @selector_full},
        "error" => [@error_full],
        "test" => %{"path" => "/t", "selector" => "t"},
        "headers" => %{"H" => ["v"]}
      },
      "search" => %{
        "path" => "/p",
        "paths" => [
          %{
            "path" => "/q",
            "method" => "post",
            "followredirect" => true,
            "categories" => ["1"],
            "inputs" => %{"a" => "b"},
            "inheritinputs" => false,
            "queryseparator" => ";",
            "response" => %{"type" => "json", "noResultsMessage" => "none"}
          }
        ],
        "allowEmptyInputs" => true,
        "inputs" => %{"q" => "k"},
        "headers" => %{"H" => ["v"]},
        "keywordsfilters" => [@filter_full],
        "error" => [@error_full],
        "preprocessingfilters" => [@filter_full],
        "rows" =>
          Map.merge(@selector_full, %{
            "filters" => [%{"name" => "andmatch", "args" => "x"}],
            "after" => 1,
            "dateheaders" => @selector_full,
            "multiple" => true,
            "missingAttributeEqualsNoResults" => true,
            "count" => @selector_full
          }),
        "fields" => %{"title" => @selector_full}
      },
      "download" => %{
        "method" => "post",
        "before" => %{
          "path" => "/b",
          "pathselector" => @selector_field_full,
          "method" => "post",
          "inputs" => %{"a" => "b"},
          "queryseparator" => ";"
        },
        "selectors" => [@selector_field_full],
        "infohash" => %{
          "hash" => @selector_field_full,
          "title" => @selector_field_full,
          "usebeforeresponse" => true
        },
        "headers" => %{"H" => ["v"]}
      }
    }

    # The keys whose atom is not the key itself.
    @renamed %{
      "requestDelay" => :request_delay,
      "allowEmptyInputs" => :allow_empty_inputs,
      "missingAttributeEqualsNoResults" => :missing_attribute_equals_no_results,
      "noResultsMessage" => :no_results_message
    }

    test "a null where a record goes fails with {:wrong_type, path}" do
      for {path, value, at} <- [
            {["caps", "categorymappings"], [nil], [:caps, :categorymappings, 0]},
            {["settings"], [nil], [:settings, 0]},
            {["search", "paths"], [nil], [:search, :paths, 0]},
            {["search", "fields"], %{"title" => nil}, [:search, :fields, 0]},
            {["search", "keywordsfilters"], [nil], [:search, :keywordsfilters, 0]}
          ] do
        assert Loader.load(yaml(put_in(@full, path, value))) == {:error, {:wrong_type, at}}
      end
    end

    test "reads every key's value back" do
      assert {:ok, definition} = Loader.load(yaml(@full))
      # Prowlarr runs `search.path` as the last entry of `search.paths`.
      {last, paths} = List.pop_at(definition.search.paths, -1)
      assert %{path: "/p", inheritinputs: true} = last
      assert_read(@full, put_in(definition, [:search, :paths], paths), [])
    end

    # JSON numbers and booleans read as text under the failsafe schema, like "x".
    test "load/1 raises on none of seven value shapes in any slot" do
      raised =
        for(
          path <- slot_paths(@full, []),
          value <- [nil, "x", ["x"], [nil], [%{}], %{}, %{"a" => nil}],
          do: {path, value}
        )
        |> Task.async_stream(fn {path, value} ->
          try do
            _answer = Loader.load(yaml(put_in(@full, path, value)))
            nil
          rescue
            error -> {path, value, Exception.message(error)}
          end
        end)
        |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)

      assert raised == []
    end
  end

  describe "the feature each slot needs" do
    # Every recognised schema key: the code it adds to a loading definition, or none when the
    # engine needs no code of its own for it.
    @path_json %{"path" => "/", "response" => %{"type" => "json"}}

    test "each recognised key adds its code, or none" do
      for {path, value, expected} <- feature_cases() do
        assert {path, value, unsupported(path, value)} == {path, value, expected}
      end
    end

    # Cardigann slice (a) builds these (#1671), so they read as supported.
    @built_settings ~w(info text password checkbox select info_flaresolverr)
    @built_filters ~w(querystring timeparse dateparse regexp re_replace split replace trim prepend
                      append tolower toupper base64decode base64encode urldecode urlencode
                      htmldecode htmlencode timeago reltime validfilename diacritics
                      jsonjoinarray hexdump strdump validate)

    # #1678 reads `rows.count` on a JSON page only, and #1679 loads it on any search, as
    # Prowlarr ignores it outside JSON.
    test "rows.count adds no code on any search, JSON, XML, HTML or mixed" do
      xml = %{"path" => "/x", "response" => %{"type" => "xml"}}

      for {paths, expected} <- [
            {[@path_json], []},
            {[@path_json, Map.put(@path_json, "path", "/2")], []},
            {[@path_json, %{"path" => "/h"}], []},
            {[xml], []},
            {[%{"path" => "/h"}], []},
            {[], []}
          ] do
        search =
          @base["search"]
          |> Map.put("paths", paths)
          |> put_in(["rows", "count"], %{"selector" => "total"})

        assert {paths, unsupported(["search"], search)} == {paths, expected}
      end
    end

    # #1679 builds `rows.after` and `rows.dateheaders` on an HTML page; #1678's XML path reads
    # neither.
    test "rows.after and rows.dateheaders add their code only on a search with an XML path" do
      xml = %{"path" => "/x", "response" => %{"type" => "xml"}}

      for {paths, expected} <- [
            {[%{"path" => "/h"}], []},
            {[@path_json], []},
            {[%{"path" => "/h"}, xml], [:rows_after, :rows_dateheaders]},
            {[xml], [:rows_after, :rows_dateheaders]}
          ] do
        search =
          @base["search"]
          |> Map.put("paths", paths)
          |> put_in(["rows", "after"], 1)
          |> put_in(["rows", "dateheaders"], %{"selector" => "td"})

        assert {paths, unsupported(["search"], search)} == {paths, expected}
      end
    end

    # `remove` beside `case` on one block reads its `case` keys on the copy `remove` left, which
    # #1679 does not build.
    test "remove with case on one block adds its code; either alone adds none" do
      for {extra, expected} <- [
            {%{"remove" => "span"}, []},
            {%{"case" => %{"a" => "1"}}, []},
            {%{"remove" => "span", "case" => %{"a" => "1"}}, [:selector_remove_case]}
          ] do
        assert unsupported(["search", "fields"], %{"title" => field(extra)}) == expected
      end
    end

    test "each settings type adds its own code, or none once built" do
      for type <-
            ~w(info text password checkbox select info_category_8000 info_cookie info_flaresolverr info_useragent) do
        setting = %{
          "name" => "a",
          "type" => type,
          "label" => "A",
          "default" => "x",
          "defaults" => ["x"],
          "options" => %{"x" => "X"}
        }

        expected = if type in @built_settings, do: [], else: [{:setting, type}]
        assert {type, unsupported(["settings"], [setting])} == {type, expected}
      end
    end

    test "every field filter of v11 and v12 adds its own code, or none once built" do
      names =
        ~w(querystring timeparse dateparse regexp re_replace split replace trim prepend append tolower toupper base64decode
           base64encode urldecode urlencode htmldecode htmlencode timeago reltime fuzzytime validfilename diacritics
           jsonjoinarray hexdump strdump validate)

      for name <- names do
        fields = %{"title" => field(%{"filters" => [filter(name)]})}
        expected = if name in @built_filters, do: [], else: [{:filter, name}]
        assert {name, unsupported(["search", "fields"], fields)} == {name, expected}
      end
    end

    test "a definition using each filter #1677 built has no filter code; the rest keep theirs" do
      filters =
        Enum.map(
          ~w(querystring timeparse prepend tolower toupper base64decode base64encode urldecode
             urlencode htmldecode htmlencode timeago reltime validfilename diacritics hexdump
             strdump validate),
          &filter/1
        )

      fields = %{"title" => field(%{"filters" => filters})}
      assert unsupported(["search", "fields"], fields) == []

      assert unsupported(["search", "keywordsfilters"], Enum.take(filters, 5)) == []

      assert unsupported(["search", "rows", "filters"], [filter("strdump")]) == []

      more = %{
        "title" => field(%{"filters" => filters ++ [filter("fuzzytime"), filter("rot13")]})
      }

      assert unsupported(["search", "fields"], more) ==
               [{:unknown_value, :filter}, {:filter, "fuzzytime"}]

      assert {:ok, definition} =
               Loader.load(
                 yaml(
                   Map.put(
                     put_in(@base, ["search", "fields"], fields),
                     "encoding",
                     "windows-1251"
                   )
                 )
               )

      assert definition.unsupported == []
    end
  end

  defp feature_cases do
    [
      # root
      {["replaces"], ["old"], []},
      {["requestDelay"], 2, []},
      {["followredirect"], true, []},
      {["followredirect"], false, []},
      {["testlinktorrent"], false, []},
      {["legacylinks"], ["https://old.invalid/"], []},
      # #1678: `LoadCheck` checks each entry is 40 hex digits; the loader reports none.
      {["certificates"], ["ab12"], []},
      {["certificates"], [], []},
      # #1678: the nine legacy charsets and UTF-8 load, any other name does not.
      {["encoding"], "windows-1251", []},
      {["encoding"], "Windows-1252", []},
      {["encoding"], "iso-8859-1", []},
      {["encoding"], "tis-620", []},
      {["encoding"], "koi8-r", [:encoding]},
      {["encoding"], "utf-16", [:encoding]},
      {["encoding"], "utf-8", []},
      {["encoding"], "UTF8", []},
      {["language"], "fr-FR", []},
      {["type"], "private", []},
      {["type"], "semi-private", []},
      # caps
      {["caps", "allowrawsearch"], true, []},
      {["caps", "allowtvsearchimdb"], true, []},
      {["caps", "categories"], %{"1" => "Movies", "2" => "TV/Anime"}, []},
      {["caps", "categorymappings"],
       [%{"id" => "1", "cat" => "Movies", "desc" => "d", "default" => true}], []},
      {["caps", "modes"],
       %{
         "search" => ["q"],
         "tv-search" => ~w(q season ep imdbid tvdbid tmdbid tvmazeid traktid doubanid year genre),
         "movie-search" => ~w(q imdbid tmdbid traktid doubanid year genre),
         "music-search" => ~w(q album artist label track year genre),
         "book-search" => ~w(q title author publisher year genre)
       }, []},
      # search
      {["search", "path"], "/", []},
      {["search", "paths"], [%{"path" => "/"}], []},
      {["search", "paths"], [@path_json], []},
      {["search", "paths"],
       [%{"path" => "/", "response" => %{"type" => "xml", "noResultsMessage" => "none"}}], []},
      {["search", "paths"], [Map.put(@path_json, "method", "post")], []},
      {["search", "paths"], [Map.put(@path_json, "method", "get")], []},
      {["search", "paths"], [Map.put(@path_json, "categories", ["1"])], []},
      {["search", "paths"], [Map.put(@path_json, "queryseparator", ";")], [:query_separator]},
      {["search", "paths"], [Map.put(@path_json, "inheritinputs", false)], [:no_inherit_inputs]},
      {["search", "paths"], [Map.put(@path_json, "followredirect", true)], []},
      {["search", "paths"], [Map.put(@path_json, "inputs", %{"$raw" => "x"})], []},
      {["search", "paths"], [Map.put(@path_json, "inputs", %{"q" => "x"})], []},
      {["search", "inputs"], %{"$raw" => "x"}, []},
      {["search", "inputs"], %{"q" => "x"}, []},
      {["search", "headers"], %{"Accept" => ["text/html"]}, []},
      {["search", "allowEmptyInputs"], true, []},
      {["search", "keywordsfilters"], [filter("trim")], []},
      {["search", "keywordsfilters"], [filter("fuzzytime")], [{:filter, "fuzzytime"}]},
      {["search", "preprocessingfilters"], [filter("trim")], []},
      {["search", "error"],
       [%{"selector" => "div.e", "path" => "/", "message" => %{"selector" => "p"}}], []},
      # rows
      {["search", "rows", "after"], 1, []},
      {["search", "rows", "after"], 0, []},
      {["search", "rows", "count"], %{"selector" => "span"}, []},
      {["search", "rows", "dateheaders"], %{"selector" => "td"}, []},
      {["search", "rows", "filters"], [filter("andmatch")], []},
      {["search", "rows", "filters"], [filter("strdump")], []},
      {["search", "rows", "multiple"], true, []},
      {["search", "rows", "missingAttributeEqualsNoResults"], true, []},
      {["search", "rows", "attribute"], "data", []},
      {["search", "rows", "optional"], true, []},
      {["search", "rows", "text"], "x", []},
      # fields
      {["search", "fields"], %{"title" => field(%{"case" => %{"a" => "1"}})}, []},
      {["search", "fields"], %{"title|noappend" => field(%{})}, [:field_modifier]},
      {["search", "fields"], %{"title" => field(%{"remove" => "span"})}, []},
      {["search", "fields"],
       %{
         "title" =>
           field(%{"attribute" => "href", "optional" => true, "default" => "x", "text" => "y"})
       }, []},
      # download
      {["download"], %{}, []},
      {["download"], %{"method" => "get"}, []},
      {["download"], %{"method" => "put"}, []},
      {["download"], %{"method" => "post"}, []},
      {["download"], %{"headers" => %{"A" => ["b"]}}, []},
      {["download"], %{"headers" => %{}}, []},
      {["download"],
       %{"selectors" => [%{"selector" => "a", "attribute" => "href", "filters" => []}]}, []},
      {["download"],
       %{"before" => %{"path" => "/b", "method" => "post", "inputs" => %{"a" => "b"}}}, []},
      {["download"],
       %{"before" => %{"pathselector" => %{"selector" => "a", "filters" => [filter("trim")]}}},
       [:download_before_pathselector]},
      {["download"], %{"before" => %{"path" => "/b", "queryseparator" => ";"}},
       [:download_before_queryseparator]},
      {["download"], %{"before" => %{"path" => "/b", "queryseparator" => "&"}}, []},
      {["download"],
       %{"infohash" => %{"hash" => %{"selector" => "h"}, "title" => %{"selector" => "t"}}}, []},
      {["download"],
       %{
         "selectors" => [%{"selector" => "a", "attribute" => "href", "usebeforeresponse" => true}]
       }, []},
      {["download"],
       %{
         "selectors" => [
           %{"selector" => "a", "attribute" => "href", "usebeforeresponse" => false}
         ]
       }, []},
      {["download"], %{"selectors" => [%{"selector" => "a", "filters" => [filter("fuzzytime")]}]},
       [{:filter, "fuzzytime"}]},
      # login
      {["login"], %{"method" => "form", "form" => "f", "submitpath" => "/s", "selectors" => true},
       [{:login, "form"}]},
      {["login"], %{"method" => "post", "inputs" => %{"u" => "x"}, "headers" => %{"A" => ["b"]}},
       [{:login, "post"}]},
      {["login"], %{"method" => "cookie", "cookies" => ["a=b"]}, [{:login, "cookie"}]},
      {["login"], %{"method" => "get", "test" => %{"path" => "/", "selector" => "a"}},
       [{:login, "get"}]},
      {["login"], %{"method" => "oneurl"}, [{:login, "oneurl"}]},
      {["login"],
       %{
         "method" => "form",
         "captcha" => %{"type" => "image", "selector" => "img", "input" => "c"}
       }, [{:login, "form"}, :login_captcha]},
      {["login"],
       %{"method" => "form", "captcha" => %{"type" => "text", "selector" => "p", "input" => "c"}},
       [{:login, "form"}, :login_captcha]},
      {["login"],
       %{
         "method" => "form",
         "selectorinputs" => %{"t" => %{"selector" => "i", "filters" => [filter("fuzzytime")]}}
       }, [{:filter, "fuzzytime"}, {:login, "form"}]},
      {["login"],
       %{
         "method" => "form",
         "getselectorinputs" => %{"t" => %{"selector" => "i", "remove" => "b"}}
       }, [{:login, "form"}]},
      {["login"],
       %{
         "method" => "form",
         "error" => [
           %{"selector" => "e", "message" => %{"selector" => "m", "remove" => "b"}}
         ]
       }, [{:login, "form"}]}
    ]
  end

  # Every key of every record in `input` reaches `parsed` under its atom, with its value: a
  # record as a map, a free-form mapping as `{key, value}` pairs, a list item by item. Each
  # record in `input` holds every key its table reads, so a key added to a table fails here until
  # `@full` holds it.
  defp assert_read(input, parsed, path) when is_map(input) and is_map(parsed) do
    atoms = Enum.map(Map.keys(input), &(Map.get(@renamed, &1) || String.to_existing_atom(&1)))
    assert Enum.sort(atoms) == Enum.sort(Map.keys(parsed) -- [:unsupported]), inspect(path)

    for {key, value} <- input do
      atom = Map.get(@renamed, key) || String.to_existing_atom(key)
      assert Map.has_key?(parsed, atom), "#{inspect(path)}: #{key} was not read"
      assert_read(value, Map.fetch!(parsed, atom), path ++ [key])
    end
  end

  defp assert_read(input, parsed, path) when is_map(input) and is_list(parsed) do
    assert Enum.sort(Enum.map(parsed, &elem(&1, 0))) == Enum.sort(Map.keys(input)), inspect(path)
    for {key, value} <- parsed, do: assert_read(Map.fetch!(input, key), value, path ++ [key])
  end

  defp assert_read(input, parsed, path) when is_list(input) do
    assert length(parsed) == length(input), inspect(path)
    for {a, b} <- Enum.zip(input, parsed), do: assert_read(a, b, path)
  end

  defp assert_read(input, parsed, path), do: assert(parsed == input, inspect(path))

  # The Access path of every value in a JSON-shaped map, maps and lists included.
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
end
