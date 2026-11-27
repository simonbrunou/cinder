defmodule Cinder.Indexers.Definitions.Loader do
  @moduledoc ~S"""
  Reads one Cardigann definition file (Prowlarr/Indexers schema v11 and v12) from its bytes and
  answers one of three things (#1664, part of #1610):

  - `{:error, reason}`: the copy fails to load;
  - `{:ok, definition}` with a non-empty `definition.unsupported`: the copy parses and is
    recognised, but uses a feature the engine has not built, or holds an unknown value in a
    fixed-value slot;
  - `{:ok, definition}` with `unsupported: []`: the copy loads.

  The module is pure: no process, no database, no network. A definition is untrusted input
  (#1615, threat model "Loading"), so `load/1` refuses, in this order:

  1. a file over `max_bytes/0` (`:too_large`), before any parsing. #1666's zip reader takes the
     same cap per file. 512 KiB is about 8 times the largest upstream file, 64,412 bytes at
     Prowlarr/Indexers `56b20b19c18f`;
  2. bytes that are not UTF-8 (`:not_utf8`);
  3. on a scan of yamerl's token stream, before any node is built: an anchor (`:yaml_anchor`)
     or an alias (`:yaml_alias`), which yaml_elixir 2.12.2 accepts and reads wrongly
     (`a: &x [1, 2]\nb: *x` gives `b => 1`); an explicit tag (`:yaml_tag`), since `!!binary`
     decodes silently; a directive (`:yaml_directive`); a second document
     (`:yaml_second_document`), of which yaml_elixir keeps the last; and a scalar key a mapping
     holds twice (`:yaml_duplicate_key`), of which yamerl keeps one value. A collection key is
     not compared, since no slot reads one: a record ignores it and a free-form mapping refuses
     it (item 5). A `&` or `*` inside a
     scalar, such as a URL query, makes no anchor or alias token and loads. Comment lines, a
     byte order mark and one `---` line stay accepted: of the 585 upstream files, 583 start
     with a `---` line, `torrent-pirat.yml` with a byte order mark before it and
     `femdomcult.yml` with comment lines above it, and none has a second document;
  4. YAML that does not parse (`{:yaml_syntax, line}`, `line` nil when yamerl names none) and a
     top level that is not a mapping (`:not_a_mapping`);
  5. a value of the wrong shape for its slot (`{:wrong_type, path}`), such as a scalar where a
     list goes or `optional: maybe`, which Prowlarr's YamlDotNet refuses too, or a null item
     where a record goes (`categorymappings: [~]`);
  6. a missing or null key that the schema marks required (`{:missing_key, path}`): root `id`,
     `name`, `description`, `language`, `type`, `encoding`, `links`, `caps` and `search`;
     `caps.modes`; `search.rows` and `search.fields`; a setting's `name` and `type`.

  Items 5 and 6 come from one walk of the records, each in its table's key order, and the first
  problem met is the reason: a file with no `id` and a `links` mapping fails `{:missing_key,
  [:id]}`.

  Every reason is built from this module's own atoms and from integers (a line, a list index in
  a `path`), never from definition text. No definition text becomes an atom: record keys map to
  atoms through the tables below, and every other key stays a string. yamerl builds atoms only
  through its `yamerl_node_erlang_atom` module, which Cinder never configures.

  The file is read as Prowlarr's model (`CardigannDefinition.cs` with YamlDotNet 18.1.0) reads it.
  yamerl parses with its failsafe schema, which keeps every scalar as text, decoded as YAML reads
  it (a quoted `"\u006E"` is `n`), so a string slot gets the text: Nyaa.si's category id `1_0`
  stays `"1_0"`, a plain `2` becomes `"2"` and a setting default `0` becomes `"0"`. A plain `""`,
  `~`, `null`, `Null` or `NULL` value is null, as YamlDotNet's `NullNodeDeserializer` reads it,
  and a quoted one is text. A boolean slot reads `true`, `y`, `yes`, `on`, `false`, `n`, `no` and
  `off` in any case, as YamlDotNet does. An integer slot (`rows.after`) reads a decimal integer
  with no leading zero, and `requestDelay` a number that `Float.parse/1` reads whole, such as `2`,
  `2.5` or `1e3`; YamlDotNet also reads `010` as octal 8 and `.5` as 0.5, which this loader
  refuses. A null or absent slot takes the model's default. A free-form mapping (`search.fields`,
  `case`, `inputs`, `options`, `categories`, `modes`, `headers`) is a list of `{key, value}` pairs
  in file order, since fields run in file order and `case` takes its first matching key, and
  `inputs: {}` reads as an absent `inputs`. A key that is a collection fails a free-form mapping
  with `{:wrong_type, path}`. A record key outside the schema, a collection key included, is
  ignored, as Prowlarr ignores an unknown key. The records hold the keys of the two `schema.json`
  files, plus `rows.default`, which the model reads; `download.selectors` holds the model's
  `SelectorField` keys plus `remove`, which #1679 reads wherever a selector block sits and
  Prowlarr's `SelectorField` lacks. The parsed definition holds no file name: #1667 keys copies by
  file name
  and blob hash.

  After reading, the loader fills in what Prowlarr's `CleanIndexerDefinition` fills in. A file
  with no `settings`, or a null one, gets Prowlarr's `username` (`text`) and `password`
  (`password`) settings, while `settings: []` gets none. A `login` with no `method` is a `form`
  login, as upstream `postman.yml` needs. A `search.path` runs as the last entry of
  `search.paths`, with `inheritinputs` on, even when `paths` has entries; `search.path` keeps its
  value too. The fourth rule, UTF-8 for a missing `encoding`, never applies, since `encoding` is
  required here.

  The feature list `features/0` holds every code the engine needs code for, each with an on or
  off flag, and `definition.unsupported` lists the codes the copy uses that are off, in that
  order, after the fixed-value slots that hold a value outside the schema
  (`{:unknown_value, slot}`, in `@unknown_slots` order). Switching a feature on is the job of the
  slice that builds it, and each such slice, like any change to what `load/1` answers, raises
  the revision in `fingerprint/0`, under which #1667 stores results.

  The flags on are the field filters `Cinder.Acquisition.Indexer.Cardigann.Filters.supported/0`
  names, which #1670 and #1677 built, the row filters `andmatch` and `strdump` (a no-op), and the
  setting types `info`, `text`, `password`, `checkbox`, `select` and `info_flaresolverr`. Then,
  by the slice that built them:

  - Cardigann slice (a) (#1671): an HTML search (`html_search`), `caps.allowrawsearch`
    (`raw_search`; Cinder never sends a raw query), `keywordsfilters`, `case`, `requestDelay`,
    the definition's own `followredirect` (`follow_redirect`) and a `categorymappings` entry
    marked `default` (`category_default`).
  - #1672: the `download` block the grab runs, its `selectors` with `testlinktorrent`
    (`download`).
  - #1678: JSON and XML search answers (`json_search`, `xml_search`) and pinned certificates
    (`certificates`), with `jsonjoinarray` among the filters.
  - #1679: a POST search path (`search_post`), the legacy `search.path` (`search_path`), path
    `categories` (`search_path_categories`), `search.headers` (`search_headers`), a `$raw` input
    (`raw_input`), `allowEmptyInputs` (`allow_empty_inputs`), `preprocessingfilters`
    (`preprocessing_filters`), `search.error` (`search_error`), a path's own `followredirect`
    (`path_follow_redirect`), `caps.allowtvsearchimdb` (`tv_search_imdb`), a selector's
    `remove` (`selector_remove`), and the `download` block's `before` (`download_before`),
    `infohash` (`download_infohash`), `method: post` (`download_post`), non-empty `headers`
    (`download_headers`) and a selector's `usebeforeresponse`
    (`download_use_before_response`).
  - #1680: the `post`, `get`, `form` and `cookie` logins (`{:login, method}`) with every login
    key but `captcha`, and the `info_cookie` setting type, a text the settings form shows,
    which every v11 `cookie` login declares.

  Every other flag is off: `{:login, "oneurl"}` and `login_captcha` among them. Some codes that
  are off are reported only for some uses:

  - `encoding` only for a name `Cinder.Acquisition.Indexer.Cardigann.Charset.fetch/1` does not
    know, so the nine legacy charsets and UTF-8 load;
  - `rows_after` (`rows.after` above 0) and `rows_dateheaders` only on a search with an XML
    path, since #1679 reads them on HTML pages only;
  - `selector_remove_case` for a selector block that sets both `remove` and `case`;
  - `download_before_pathselector` for a `before.pathselector`, and
    `download_before_queryseparator` for a `before.queryseparator` other than `&`. No v11
    definition at Prowlarr/Indexers `56b20b19` sets either.

  A field whose name holds `|`, a modifier Prowlarr reads after the name, is `field_modifier`.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.Charset

  @max_bytes 524_288
  @schema_version 12
  # 2: `Cinder.Indexers.Definitions.LoadCheck` adds the selector codes (#1665).
  # 3: the filters of #1677 load, and `LoadCheck` adds the static pattern codes.
  # 4: Cardigann slice (a) switches on what Nyaa.si and Torrent9 use, and `LoadCheck` adds the
  #    static layout code (#1671).
  # 5: the grab runs a `download` block with `selectors` (#1672), and `LoadCheck` renders a
  #    download selector that holds a template.
  # 6: JSON and XML responses, `jsonjoinarray`, the legacy charsets and pinned certificates
  #    load (#1678), `rows.count` loads on a JSON-only search, and `LoadCheck` adds the JSON
  #    path, XML selector and certificate codes.
  # 7: the remaining search and download keys load (#1679), `rows.count` loads on any search
  #    and `LoadCheck` checks it on a JSON copy only, and `LoadCheck` renders a field selector
  #    that reads `.Result` and checks a download selector's `remove`.
  # 8: the `post`, `get`, `form` and `cookie` logins and the `info_cookie` setting type load
  #    (#1680), and `LoadCheck` checks a `login.inputs` key read as a selector.
  # 9: the definitions store keeps each copy's display name with its result (#1676), which the
  #    boot re-check fills in for every stored copy.
  @revision 9

  @field_filters ~w(querystring timeparse dateparse regexp re_replace split replace trim prepend
                    append tolower toupper base64decode base64encode urldecode urlencode
                    htmldecode htmlencode timeago reltime fuzzytime validfilename diacritics
                    jsonjoinarray hexdump strdump validate)
  @row_filters ~w(andmatch strdump)
  # The filters #1670 and #1677 built, and #1671's row filter and setting types.
  @built_filters Cinder.Acquisition.Indexer.Cardigann.Filters.supported()
  @built_row_filters ~w(andmatch strdump)
  @built_setting_types ~w(info text password checkbox select info_cookie info_flaresolverr)
  @login_methods ~w(form post cookie get oneurl)
  # The login methods #1680 built.
  @built_login_methods ~w(form post cookie get)
  @setting_types ~w(info text password checkbox select info_category_8000 info_cookie
                    info_flaresolverr info_useragent)
  @privacy_types ~w(public semi-private private)
  @captcha_types ~w(image text)
  @mode_parameters %{
    "search" => ~w(q),
    "tv-search" => ~w(q season ep imdbid tvdbid tmdbid tvmazeid traktid doubanid year genre),
    "movie-search" => ~w(q imdbid tmdbid traktid doubanid year genre),
    "music-search" => ~w(q album artist label track year genre),
    "book-search" => ~w(q title author publisher year genre)
  }
  @categories [
    "Console",
    "Console/NDS",
    "Console/PSP",
    "Console/Wii",
    "Console/XBox",
    "Console/XBox 360",
    "Console/Wiiware",
    "Console/XBox 360 DLC",
    "Console/PS3",
    "Console/Other",
    "Console/3DS",
    "Console/PS Vita",
    "Console/WiiU",
    "Console/XBox One",
    "Console/PS4",
    "Movies",
    "Movies/Foreign",
    "Movies/Other",
    "Movies/SD",
    "Movies/HD",
    "Movies/UHD",
    "Movies/BluRay",
    "Movies/3D",
    "Movies/DVD",
    "Movies/WEB-DL",
    "Audio",
    "Audio/MP3",
    "Audio/Video",
    "Audio/Audiobook",
    "Audio/Lossless",
    "Audio/Other",
    "Audio/Foreign",
    "PC",
    "PC/0day",
    "PC/ISO",
    "PC/Mac",
    "PC/Mobile-Other",
    "PC/Games",
    "PC/Mobile-iOS",
    "PC/Mobile-Android",
    "TV",
    "TV/WEB-DL",
    "TV/Foreign",
    "TV/SD",
    "TV/HD",
    "TV/UHD",
    "TV/Other",
    "TV/Sport",
    "TV/Anime",
    "TV/Documentary",
    "XXX",
    "XXX/DVD",
    "XXX/WMV",
    "XXX/XviD",
    "XXX/x264",
    "XXX/UHD",
    "XXX/Pack",
    "XXX/ImageSet",
    "XXX/Other",
    "XXX/SD",
    "XXX/WEB-DL",
    "Books",
    "Books/Mags",
    "Books/EBook",
    "Books/Comics",
    "Books/Technical",
    "Books/Other",
    "Books/Foreign",
    "Other",
    "Other/Misc",
    "Other/Hashed"
  ]

  @unknown_slots [
    :privacy_type,
    :mode,
    :mode_parameter,
    :category,
    :setting_type,
    :login_method,
    :captcha_type,
    :response_type,
    :row_filter,
    :filter
  ]

  # Every code the engine needs code for, in the order `unsupported` lists them, each with its
  # flag: true once a slice builds it.
  @features [
              html_search: true,
              json_search: true,
              xml_search: true,
              search_post: true,
              search_path: true,
              search_path_categories: true,
              query_separator: false,
              no_inherit_inputs: false,
              search_headers: true,
              raw_input: true,
              raw_search: true,
              allow_empty_inputs: true,
              keywords_filters: true,
              preprocessing_filters: true,
              search_error: true,
              rows_after: false,
              rows_dateheaders: false,
              selector_case: true,
              selector_remove: true,
              selector_remove_case: false,
              field_modifier: false
            ] ++
              Enum.map(@row_filters, &{{:row_filter, &1}, &1 in @built_row_filters}) ++
              Enum.map(@field_filters, &{{:filter, &1}, &1 in @built_filters}) ++
              [
                download: true,
                download_before: true,
                download_before_pathselector: false,
                download_before_queryseparator: false,
                download_infohash: true,
                download_post: true,
                download_headers: true,
                download_use_before_response: true,
                request_delay: true,
                follow_redirect: true,
                path_follow_redirect: true,
                encoding: false,
                certificates: true,
                category_default: true,
                tv_search_imdb: true
              ] ++
              Enum.map(@login_methods, &{{:login, &1}, &1 in @built_login_methods}) ++
              [login_captcha: false] ++
              Enum.map(@setting_types, &{{:setting, &1}, &1 in @built_setting_types})

  # Each record of the schema: its keys as the file writes them, the atom the parsed definition
  # uses, and the slot's kind. `{:bool, default}` and `{:int, default}` carry the model's default.
  @selector [
    {"selector", :selector, :string},
    {"attribute", :attribute, :string},
    {"optional", :optional, {:bool, false}},
    {"default", :default, :string},
    {"case", :case, {:map, :string}},
    {"remove", :remove, :string},
    {"text", :text, :string},
    {"filters", :filters, {:list, {:record, :filter}}}
  ]

  @records %{
    root: [
      {"id", :id, :string},
      {"replaces", :replaces, {:list, :string}},
      {"name", :name, :string},
      {"description", :description, :string},
      {"language", :language, :string},
      {"type", :type, :string},
      {"encoding", :encoding, :string},
      {"followredirect", :followredirect, {:bool, false}},
      {"testlinktorrent", :testlinktorrent, {:bool, true}},
      {"requestDelay", :request_delay, :float},
      {"links", :links, {:list, :string}},
      {"legacylinks", :legacylinks, {:list, :string}},
      {"certificates", :certificates, {:list, :string}},
      {"caps", :caps, {:record, :caps}},
      {"settings", :settings, {:list, {:record, :setting}}},
      {"login", :login, {:record, :login}},
      {"search", :search, {:record, :search}},
      {"download", :download, {:record, :download}}
    ],
    caps: [
      {"categories", :categories, {:map, :string}},
      {"categorymappings", :categorymappings, {:list, {:record, :category_mapping}}},
      {"modes", :modes, {:map, {:list, :string}}},
      {"allowrawsearch", :allowrawsearch, {:bool, false}},
      {"allowtvsearchimdb", :allowtvsearchimdb, {:bool, false}}
    ],
    category_mapping: [
      {"id", :id, :string},
      {"cat", :cat, :string},
      {"desc", :desc, :string},
      {"default", :default, {:bool, false}}
    ],
    setting: [
      {"name", :name, :string},
      {"label", :label, :string},
      {"type", :type, :string},
      {"default", :default, :string},
      {"options", :options, {:map, :string}},
      {"defaults", :defaults, {:list, :string}}
    ],
    login: [
      {"method", :method, :string},
      {"cookies", :cookies, {:list, :string}},
      {"path", :path, :string},
      {"submitpath", :submitpath, :string},
      {"form", :form, :string},
      {"captcha", :captcha, {:record, :captcha}},
      {"inputs", :inputs, {:map, :string}},
      {"selectors", :selectors, {:bool, false}},
      {"selectorinputs", :selectorinputs, {:map, {:record, :selector}}},
      {"getselectorinputs", :getselectorinputs, {:map, {:record, :selector}}},
      {"error", :error, {:list, {:record, :error}}},
      {"test", :test, {:record, :page_test}},
      {"headers", :headers, {:map, {:list, :string}}}
    ],
    page_test: [{"path", :path, :string}, {"selector", :selector, :string}],
    captcha: [
      {"type", :type, :string},
      {"selector", :selector, :string},
      {"input", :input, :string}
    ],
    error: [
      {"path", :path, :string},
      {"selector", :selector, :string},
      {"message", :message, {:record, :selector}}
    ],
    selector: @selector,
    filter: [{"name", :name, :string}, {"args", :args, :args}],
    row_filter: [{"name", :name, :string}, {"args", :args, :args}],
    search: [
      {"path", :path, :string},
      {"paths", :paths, {:list, {:record, :search_path}}},
      {"allowEmptyInputs", :allow_empty_inputs, {:bool, false}},
      {"inputs", :inputs, {:map, :string}},
      {"headers", :headers, {:map, {:list, :string}}},
      {"keywordsfilters", :keywordsfilters, {:list, {:record, :filter}}},
      {"error", :error, {:list, {:record, :error}}},
      {"preprocessingfilters", :preprocessingfilters, {:list, {:record, :filter}}},
      {"rows", :rows, {:record, :rows}},
      {"fields", :fields, {:map, {:record, :selector}}}
    ],
    search_path: [
      {"path", :path, :string},
      {"method", :method, :string},
      {"followredirect", :followredirect, {:bool, false}},
      {"categories", :categories, {:list, :string}},
      {"inputs", :inputs, {:map, :string}},
      {"inheritinputs", :inheritinputs, {:bool, true}},
      {"queryseparator", :queryseparator, {:string, "&"}},
      {"response", :response, {:record, :response}}
    ],
    response: [
      {"type", :type, :string},
      {"noResultsMessage", :no_results_message, :string}
    ],
    rows:
      List.keyreplace(
        @selector,
        "filters",
        0,
        {"filters", :filters, {:list, {:record, :row_filter}}}
      ) ++
        [
          {"after", :after, {:int, 0}},
          {"dateheaders", :dateheaders, {:record, :selector}},
          {"multiple", :multiple, {:bool, false}},
          {"missingAttributeEqualsNoResults", :missing_attribute_equals_no_results,
           {:bool, false}},
          {"count", :count, {:record, :selector}}
        ],
    download: [
      {"method", :method, :string},
      {"before", :before, {:record, :before}},
      {"selectors", :selectors, {:list, {:record, :selector_field}}},
      {"infohash", :infohash, {:record, :infohash}},
      {"headers", :headers, {:map, {:list, :string}}}
    ],
    before: [
      {"path", :path, :string},
      {"pathselector", :pathselector, {:record, :selector_field}},
      {"method", :method, :string},
      {"inputs", :inputs, {:map, :string}},
      {"queryseparator", :queryseparator, {:string, "&"}}
    ],
    infohash: [
      {"hash", :hash, {:record, :selector_field}},
      {"title", :title, {:record, :selector_field}},
      {"usebeforeresponse", :usebeforeresponse, {:bool, false}}
    ],
    selector_field: [
      {"selector", :selector, :string},
      {"attribute", :attribute, :string},
      {"remove", :remove, :string},
      {"usebeforeresponse", :usebeforeresponse, {:bool, false}},
      {"filters", :filters, {:list, {:record, :filter}}}
    ]
  }

  @required %{
    root: [:id, :name, :description, :language, :type, :encoding, :links, :caps, :search],
    caps: [:modes],
    search: [:rows, :fields],
    setting: [:name, :type]
  }

  @null_spellings [~c"", ~c"~", ~c"null", ~c"Null", ~c"NULL"]

  # The settings Prowlarr gives a definition with no `settings`.
  @default_settings [
    %{name: "username", label: "Username", type: "text"},
    %{name: "password", label: "Password", type: "password"}
  ]

  @type reason ::
          :too_large
          | :not_utf8
          | :yaml_anchor
          | :yaml_alias
          | :yaml_tag
          | :yaml_directive
          | :yaml_second_document
          | :yaml_duplicate_key
          | {:yaml_syntax, pos_integer() | nil}
          | :not_a_mapping
          | {:wrong_type, [atom() | non_neg_integer()]}
          | {:missing_key, [atom() | non_neg_integer()]}

  @doc "The size cap in bytes: a larger file fails to load with `:too_large` before parsing."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The schema version the engine declares and the loader's revision. A slice that switches a
  feature on, or changes what `load/1` answers, raises the revision.
  """
  @spec fingerprint() :: %{schema_version: pos_integer(), revision: pos_integer()}
  def fingerprint, do: %{schema_version: @schema_version, revision: @revision}

  @doc "The fixed-value slots whose unknown value reads `{:unknown_value, slot}`, in report order."
  @spec unknown_slots() :: [atom()]
  def unknown_slots, do: @unknown_slots

  @doc "Every feature code in report order, each with its flag: true once the engine builds it."
  @spec features() :: [{term(), boolean()}]
  def features, do: @features

  @doc """
  Reads one definition file's bytes. See the moduledoc for the three answers and each refusal.
  """
  @spec load(binary()) :: {:ok, map()} | {:error, reason()}
  def load(bytes) when is_binary(bytes) do
    with :ok <- check_size(bytes),
         :ok <- check_utf8(bytes),
         {:ok, nulls} <- scan(bytes),
         {:ok, root} <- construct(bytes) do
      read_definition(root, nulls)
    end
  end

  defp check_size(bytes) when byte_size(bytes) > @max_bytes, do: {:error, :too_large}
  defp check_size(_bytes), do: :ok

  defp check_utf8(bytes), do: if(String.valid?(bytes), do: :ok, else: {:error, :not_utf8})

  ## The token scan

  # yamerl hands each token to `token_fun`, which returns the next fun: the scan's state travels
  # in that closure, and a refusal throws out of the parser at once. The final fun, read back
  # from the parser, returns the positions of plain null scalars that are not keys.
  defp scan(bytes) do
    parser = :yamerl_parser.string(bytes, token_fun: scanner(%{docs: 0, frames: [], nulls: []}))
    state = :yamerl_parser.get_token_fun(parser).(:state)
    {:ok, MapSet.new(state.nulls)}
  catch
    :throw, {__MODULE__, reason} -> {:error, reason}
    :throw, {:yamerl_exception, errors} -> {:error, syntax_error(errors)}
  end

  defp scanner(state) do
    fn
      :state -> state
      token -> {:ok, scanner(step(token, state))}
    end
  end

  defp step({:yamerl_doc_start, _, _, _, _}, %{docs: 0} = state), do: %{state | docs: 1}
  defp step({:yamerl_doc_start, _, _, _, _}, _state), do: refuse(:yaml_second_document)
  defp step({:yamerl_anchor, _, _, _}, _state), do: refuse(:yaml_anchor)
  defp step({:yamerl_alias, _, _, _}, _state), do: refuse(:yaml_alias)

  defp step(token, _state)
       when elem(token, 0) in [
              :yamerl_yaml_directive,
              :yamerl_tag_directive,
              :yamerl_reserved_directive
            ],
       do: refuse(:yaml_directive)

  defp step({:yamerl_collection_start, line, column, tag, _style, _kind}, state) do
    check_tag(tag, line, column, :collection)
    frames = mark_value(state.frames)
    %{state | frames: [%{keys: MapSet.new(), key?: false} | frames]}
  end

  defp step({:yamerl_collection_end, _, _, _, _}, %{frames: [_top | rest]} = state),
    do: %{state | frames: rest}

  defp step({:yamerl_mapping_key, _, _}, %{frames: [top | rest]} = state),
    do: %{state | frames: [%{top | key?: true} | rest]}

  defp step({:yamerl_scalar, line, column, tag, _style, substyle, text}, state) do
    check_tag(tag, line, column, substyle)

    case state.frames do
      [%{key?: true} = top | rest] ->
        key = List.to_string(text)
        if MapSet.member?(top.keys, key), do: refuse(:yaml_duplicate_key)
        %{state | frames: [%{top | key?: false, keys: MapSet.put(top.keys, key)} | rest]}

      _ when substyle == :plain and text in @null_spellings ->
        %{state | nulls: [{line, column} | state.nulls]}

      _ ->
        state
    end
  end

  defp step(_token, state), do: state

  # A collection that is a key opens with the frame still waiting for its key.
  defp mark_value([%{key?: true} = top | rest]), do: [%{top | key?: false} | rest]
  defp mark_value(frames), do: frames

  # yamerl gives every node a tag. An implied one sits where its node does: `?` on a plain scalar
  # or a collection, `!` on a quoted or block scalar. Any other is written in the file. Written
  # before a value it sits before the node, and on an empty value (`a: !!str`, `a: !`) where the
  # node does, with its own name or a `!` on a plain scalar.
  defp check_tag({:yamerl_tag, line, column, {:non_specific, ~c"?"}}, line, column, _substyle),
    do: :ok

  defp check_tag({:yamerl_tag, line, column, {:non_specific, ~c"!"}}, line, column, substyle)
       when substyle not in [:plain, :collection],
       do: :ok

  defp check_tag(_tag, _line, _column, _substyle), do: refuse(:yaml_tag)

  defp refuse(reason), do: throw({__MODULE__, reason})

  defp syntax_error([
         {:yamerl_parsing_error, _type, _text, line, _col, _name, _token, _extra} | _
       ])
       when is_integer(line),
       do: {:yaml_syntax, line}

  defp syntax_error(_errors), do: {:yaml_syntax, nil}

  ## Building the nodes

  defp construct(bytes) do
    options = [:str_node_as_binary, {:schema, :failsafe}, {:detailed_constr, true}]

    case :yamerl_constr.string(bytes, options) do
      [{:yamerl_doc, {:yamerl_map, _, _, _, _} = root}] -> {:ok, root}
      _other -> {:error, :not_a_mapping}
    end
  catch
    :throw, {:yamerl_exception, errors} -> {:error, syntax_error(errors)}
  end

  ## Reading the nodes into the definition

  defp read_definition(root, nulls) do
    definition = {:record, :root} |> read(root, [], nulls) |> clean(settings?(root, nulls))
    {:ok, Map.put(definition, :unsupported, unsupported(definition))}
  catch
    :throw, {__MODULE__, reason} -> {:error, reason}
  end

  # What Prowlarr's `CleanIndexerDefinition` fills in after reading the file. Its fourth rule, a
  # UTF-8 `encoding` when none is given, never applies: `encoding` is required here.
  defp clean(definition, settings?) do
    %{
      definition
      | settings: if(settings?, do: definition.settings, else: default_settings()),
        login: with_login_method(definition.login),
        search: with_search_path(definition.search)
    }
  end

  defp default_settings, do: Enum.map(@default_settings, &Map.merge(blank(:setting), &1))

  defp with_login_method(%{method: nil} = login), do: %{login | method: "form"}
  defp with_login_method(login), do: login

  defp with_search_path(%{path: nil} = search), do: search

  defp with_search_path(search) do
    path = %{blank(:search_path) | path: search.path, inheritinputs: true}
    %{search | paths: search.paths ++ [path]}
  end

  # Whether the root holds a `settings` key with a value: `settings: []` keeps the defaults out.
  defp settings?({:yamerl_map, _, _, _, pairs}, nulls) do
    Enum.any?(pairs, fn {key, value} ->
      match?({:yamerl_str, _, _, _, "settings"}, key) and not null?(value, nulls)
    end)
  end

  # A record with every key at its default.
  defp blank(name),
    do: Map.new(@records[name], fn {_key, atom, kind} -> {atom, default(kind)} end)

  defp read(kind, node, path, nulls) do
    if null?(node, nulls), do: default(kind), else: typed(kind, node, path, nulls)
  end

  defp null?({:yamerl_str, _, _, pres, text}, nulls),
    do: MapSet.member?(nulls, {pres[:line], pres[:column]}) and null_text?(text)

  defp null?(_node, _nulls), do: false

  defp null_text?(text), do: String.to_charlist(text) in @null_spellings

  # An item of a list or of a free-form mapping. A null where a record goes has no record to
  # read, so it refuses the file; YamlDotNet would hand Prowlarr a null entry there.
  defp item({:record, _name} = kind, node, path, nulls) do
    if null?(node, nulls), do: refuse({:wrong_type, path}), else: typed(kind, node, path, nulls)
  end

  defp item(kind, node, path, nulls), do: read(kind, node, path, nulls)

  defp default({:bool, value}), do: value
  defp default({:int, value}), do: value
  defp default({:string, value}), do: value
  defp default({:list, _kind}), do: []
  defp default({:map, _kind}), do: []
  defp default(_kind), do: nil

  defp typed(kind, {:yamerl_str, _, _, _, text}, path, _nulls), do: scalar(kind, text, path)

  defp typed({:list, kind}, {:yamerl_seq, _, _, _, items, _count}, path, nulls) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> item(kind, item, path ++ [index], nulls) end)
  end

  defp typed({:map, kind}, {:yamerl_map, _, _, _, pairs}, path, nulls) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn
      {{{:yamerl_str, _, _, _, key}, value}, index} ->
        {key, item(kind, value, path ++ [index], nulls)}

      {_pair, index} ->
        refuse({:wrong_type, path ++ [index]})
    end)
  end

  defp typed({:record, name}, {:yamerl_map, _, _, _, pairs}, path, nulls),
    do: record(name, pairs, path, nulls)

  defp typed(:args, {:yamerl_seq, _, _, _, _, _} = node, path, nulls),
    do: typed({:list, :string}, node, path, nulls)

  defp typed(_kind, _node, path, _nulls), do: refuse({:wrong_type, path})

  defp scalar(kind, text, _path) when kind in [:string, :args], do: text
  defp scalar({:string, _default}, text, _path), do: text

  defp scalar({:bool, _default}, text, path) do
    cond do
      String.downcase(text) in ~w(true y yes on) -> true
      String.downcase(text) in ~w(false n no off) -> false
      true -> refuse({:wrong_type, path})
    end
  end

  defp scalar({:int, _default}, text, path) do
    if text =~ ~r/\A[+-]?(0|[1-9][0-9]*)\z/,
      do: String.to_integer(text),
      else: refuse({:wrong_type, path})
  end

  # `Float.parse/1` reads `2`, `2.5`, `+2` and `1e3`, and reads `.5`, `5.` or `1e400` as no
  # whole number.
  defp scalar(:float, text, path) do
    case Float.parse(text) do
      {value, ""} -> value
      _other -> refuse({:wrong_type, path})
    end
  end

  defp scalar(_kind, _text, path), do: refuse({:wrong_type, path})

  defp record(name, pairs, path, nulls) do
    nodes = Map.new(for {{:yamerl_str, _, _, _, key}, value} <- pairs, do: {key, value})
    required = Map.get(@required, name, [])

    Map.new(@records[name], fn {key, atom, kind} ->
      node = Map.get(nodes, key)

      cond do
        atom in required and (node == nil or null?(node, nulls)) ->
          refuse({:missing_key, path ++ [atom]})

        node == nil ->
          {atom, default(kind)}

        true ->
          {atom, read(kind, node, path ++ [atom], nulls)}
      end
    end)
  end

  ## The unsupported features

  defp unsupported(definition) do
    {unknown, used} = definition |> uses() |> Enum.split_with(&match?({:unknown_value, _}, &1))
    unknown = MapSet.new(unknown)
    used = MapSet.new(used)

    for(slot <- @unknown_slots, {:unknown_value, slot} in unknown, do: {:unknown_value, slot}) ++
      for {code, false} <- @features, code in used, do: code
  end

  defp uses(d) do
    root_uses(d) ++
      caps_uses(d.caps) ++
      Enum.flat_map(d.settings, &setting_uses/1) ++
      login_uses(d.login) ++
      search_uses(d.search) ++
      download_uses(d.download) ++
      walk(d, [])
  end

  defp root_uses(d) do
    [
      unless(d.type in @privacy_types, do: {:unknown_value, :privacy_type}),
      if(d.request_delay, do: :request_delay),
      if(d.followredirect, do: :follow_redirect),
      if(Charset.fetch(d.encoding) == :error, do: :encoding),
      if(d.certificates != [], do: :certificates)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp caps_uses(caps) do
    categories =
      Enum.map(caps.categories, &elem(&1, 1)) ++ Enum.map(caps.categorymappings, & &1.cat)

    [
      if(caps.allowrawsearch, do: :raw_search),
      if(caps.allowtvsearchimdb, do: :tv_search_imdb),
      if(Enum.any?(caps.categorymappings, & &1.default), do: :category_default),
      unless(Enum.all?(categories, &(&1 in @categories)), do: {:unknown_value, :category})
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Enum.flat_map(caps.modes, &mode_uses/1))
  end

  defp mode_uses({mode, parameters}) do
    case Map.fetch(@mode_parameters, mode) do
      {:ok, known} ->
        if Enum.all?(parameters, &(&1 in known)),
          do: [],
          else: [{:unknown_value, :mode_parameter}]

      :error ->
        [{:unknown_value, :mode}]
    end
  end

  defp setting_uses(%{type: type}) when type in @setting_types, do: [{:setting, type}]
  defp setting_uses(_setting), do: [{:unknown_value, :setting_type}]

  defp login_uses(nil), do: []

  defp login_uses(login) do
    method =
      if login.method in @login_methods,
        do: {:login, login.method},
        else: {:unknown_value, :login_method}

    [method | captcha_uses(login.captcha)]
  end

  defp captcha_uses(nil), do: []
  defp captcha_uses(%{type: type}) when type in @captcha_types, do: [:login_captcha]
  defp captcha_uses(_captcha), do: [:login_captcha, {:unknown_value, :captcha_type}]

  defp search_uses(search) do
    [
      if(search.path, do: :search_path),
      if(search.allow_empty_inputs, do: :allow_empty_inputs),
      if(search.headers != [], do: :search_headers),
      if(search.keywordsfilters != [], do: :keywords_filters),
      if(search.preprocessingfilters != [], do: :preprocessing_filters),
      if(search.error != [], do: :search_error),
      if(raw_input?(search.inputs), do: :raw_input),
      if(Enum.any?(search.fields, fn {name, _field} -> String.contains?(name, "|") end),
        do: :field_modifier
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Enum.flat_map(search.paths, &path_uses/1))
    |> Kernel.++(rows_uses(search.rows, xml_path?(search.paths)))
  end

  # `rows.after` and `dateheaders` run on an HTML page and a JSON page ignores them, as
  # Prowlarr's does (#1679); the XML path does not run them, so a search with an XML path still
  # reports them.
  defp xml_path?(paths), do: Enum.any?(paths, &match?(%{response: %{type: "xml"}}, &1))

  defp path_uses(path) do
    [
      response_use(path.response),
      unless(path.method in [nil, "get"], do: :search_post),
      if(path.categories != [], do: :search_path_categories),
      if(path.followredirect, do: :path_follow_redirect),
      unless(path.inheritinputs, do: :no_inherit_inputs),
      unless(path.queryseparator == "&", do: :query_separator),
      if(raw_input?(path.inputs), do: :raw_input)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp response_use(nil), do: :html_search
  defp response_use(%{type: "json"}), do: :json_search
  defp response_use(%{type: "xml"}), do: :xml_search
  defp response_use(_response), do: {:unknown_value, :response_type}

  defp raw_input?(inputs), do: List.keymember?(inputs, "$raw", 0)

  # `rows.count` loads on any search: a JSON page reads it (#1678) and every other page ignores
  # it, as Prowlarr's does (#1679).
  defp rows_uses(rows, xml_path?) do
    filters =
      Enum.map(rows.filters, fn
        %{name: name} when name in @row_filters -> {:row_filter, name}
        _filter -> {:unknown_value, :row_filter}
      end)

    [
      if(rows.after > 0 and xml_path?, do: :rows_after),
      if(rows.dateheaders && xml_path?, do: :rows_dateheaders)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(filters)
  end

  defp download_uses(nil), do: []

  defp download_uses(download) do
    [
      :download,
      if(download.infohash, do: :download_infohash),
      if(download.method == "post", do: :download_post),
      if(download.headers != [], do: :download_headers),
      if(Enum.any?(download.selectors, & &1.usebeforeresponse),
        do: :download_use_before_response
      )
      | before_uses(download.before)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp before_uses(nil), do: []

  defp before_uses(before) do
    [
      :download_before,
      if(before.pathselector, do: :download_before_pathselector),
      if(before.queryseparator != "&", do: :download_before_queryseparator)
    ]
  end

  # Every field filter list, `case` block and `remove` in the definition, wherever its selector
  # block sits. `search.rows.filters` holds row filters, which `rows_uses/2` reads.
  defp walk(map, path) when is_map(map) do
    remove_case_use(map) ++
      Enum.flat_map(map, fn {key, value} ->
        key_uses(key, value, path) ++ walk(value, [key | path])
      end)
  end

  defp walk(list, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, path))
  defp walk({key, value}, path) when is_binary(key), do: walk(value, path)
  defp walk(_value, _path), do: []

  # A selector block with `remove` and `case`: Prowlarr matches the case keys after the removal,
  # which Cinder does not build (#1679), so it stays off.
  defp remove_case_use(%{remove: remove, case: [_ | _]}) when is_binary(remove),
    do: [:selector_remove_case]

  defp remove_case_use(_map), do: []

  defp key_uses(:filters, filters, [:rows, :search]) when is_list(filters), do: []

  defp key_uses(key, filters, _path)
       when key in [:filters, :keywordsfilters, :preprocessingfilters],
       do: Enum.map(filters, &filter_use/1)

  defp key_uses(:case, [_ | _], _path), do: [:selector_case]
  defp key_uses(:remove, remove, _path) when is_binary(remove), do: [:selector_remove]
  defp key_uses(_key, _value, _path), do: []

  defp filter_use(%{name: name}) when name in @field_filters, do: {:filter, name}
  defp filter_use(_filter), do: {:unknown_value, :filter}
end
