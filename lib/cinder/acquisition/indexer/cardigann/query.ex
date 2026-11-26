defmodule Cinder.Acquisition.Indexer.Cardigann.Query do
  @moduledoc """
  Plans one seam call against one Cardigann definition (#1671; #1618 points 8 to 10 and 13):
  which queries it asks, with which variables, and the GET URL of each search path. Pure: no
  request, no process.

  ## Which queries

  `caps.modes` decides with Newznab's rules (`Cinder.Acquisition.Indexer.Newznab`'s table):

  | Seam call | Query | Origin |
  |---|---|---|
  | `search(imdb)` | `.Query.IMDBID`, when `movie-search` lists `imdbid` | id-scoped |
  | `search_tv` with a TVDB id | `.Query.TVDBID` and `.Query.Season`, when `tv-search` lists `tvdbid` | id-scoped |
  | `search_tv` | the title plus ` S<nn>` for a season above 0, when `tv-search` lists `q` and `season`, else when `search` lists `q` | free text |
  | the four `*_query` calls | the text, when `search` lists `q` | free text |
  | `search_ebook`, `search_audiobook` | `.Query.Title` and `.Query.Author`, when `book-search` lists `title`, and `author` when one is sent | id-scoped |

  An id-scoped query has empty keywords. Native never sends an episode.

  ## Categories

  The call's categories, else its default (movie 2000, TV 5000, e-book 7020, audiobook 3030),
  reach each `categorymappings` (and `caps.categories`) entry whose standard category is one of
  them or a child of one (`Cinder.Acquisition.Indexer.Newznab.Caps.categories/2`). The site ids
  of every entry reached, each once in file order, are `.Categories`. A query that reaches none
  is not asked, even when an entry is marked `default`: the default entries are for a call with
  no category, which only the Test makes (`test_plan/3`).

  ## Variables

  `.Config.<name>` holds each declared setting's stored value, else its default: a checkbox
  `.True` when on and nothing when off, a select its option key, a text or password setting its
  value. `.Config.sitelink` is the effective base URL. `.Query.Keywords` holds the keywords
  before the definition's keyword filters and `.Keywords` after them.

  ## Paths

  Each search path, in file order: the path template rendered with each value URL-encoded
  (spaces as `%20`) and resolved against the base URL, then the search inputs followed by the
  path's own, each rendered and left out when blank, appended as a query string. An input name
  in both lists is sent twice, search value first, as Prowlarr's `GetRequest` sends it. Two paths
  that render one URL send it once.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{Filters, Template, Variables}
  alias Cinder.Acquisition.Indexer.Newznab.Caps

  @movie_category 2000
  @tv_category 5000
  @ebook_category 7020
  @audiobook_category 3030

  # Prowlarr's standard categories by name (`NewznabStandardCategory.AllCats`, b0b5774): its
  # `GetCatByName` takes the first, so `Other` is 8000, not 0.
  @category_ids %{
    "Console" => 1000,
    "Console/NDS" => 1010,
    "Console/PSP" => 1020,
    "Console/Wii" => 1030,
    "Console/XBox" => 1040,
    "Console/XBox 360" => 1050,
    "Console/Wiiware" => 1060,
    "Console/XBox 360 DLC" => 1070,
    "Console/PS3" => 1080,
    "Console/Other" => 1090,
    "Console/3DS" => 1110,
    "Console/PS Vita" => 1120,
    "Console/WiiU" => 1130,
    "Console/XBox One" => 1140,
    "Console/PS4" => 1180,
    "Movies" => 2000,
    "Movies/Foreign" => 2010,
    "Movies/Other" => 2020,
    "Movies/SD" => 2030,
    "Movies/HD" => 2040,
    "Movies/UHD" => 2045,
    "Movies/BluRay" => 2050,
    "Movies/3D" => 2060,
    "Movies/DVD" => 2070,
    "Movies/WEB-DL" => 2080,
    "Movies/x265" => 2090,
    "Audio" => 3000,
    "Audio/MP3" => 3010,
    "Audio/Video" => 3020,
    "Audio/Audiobook" => 3030,
    "Audio/Lossless" => 3040,
    "Audio/Other" => 3050,
    "Audio/Foreign" => 3060,
    "PC" => 4000,
    "PC/0day" => 4010,
    "PC/ISO" => 4020,
    "PC/Mac" => 4030,
    "PC/Mobile-Other" => 4040,
    "PC/Games" => 4050,
    "PC/Mobile-iOS" => 4060,
    "PC/Mobile-Android" => 4070,
    "TV" => 5000,
    "TV/WEB-DL" => 5010,
    "TV/Foreign" => 5020,
    "TV/SD" => 5030,
    "TV/HD" => 5040,
    "TV/UHD" => 5045,
    "TV/Other" => 5050,
    "TV/Sport" => 5060,
    "TV/Anime" => 5070,
    "TV/Documentary" => 5080,
    "TV/x265" => 5090,
    "XXX" => 6000,
    "XXX/DVD" => 6010,
    "XXX/WMV" => 6020,
    "XXX/XviD" => 6030,
    "XXX/x264" => 6040,
    "XXX/UHD" => 6045,
    "XXX/Pack" => 6050,
    "XXX/ImageSet" => 6060,
    "XXX/Other" => 6070,
    "XXX/SD" => 6080,
    "XXX/WEB-DL" => 6090,
    "Books" => 7000,
    "Books/Mags" => 7010,
    "Books/EBook" => 7020,
    "Books/Comics" => 7030,
    "Books/Technical" => 7040,
    "Books/Other" => 7050,
    "Books/Foreign" => 7060,
    "Other" => 8000,
    "Other/Misc" => 8010,
    "Other/Hashed" => 8020
  }

  @typedoc """
  The stored values one plan reads: the effective base URL, its `#` part cut
  (`Cinder.HTTPPolicy.without_fragment/1`), and every setting's value.
  """
  @type config :: %{
          required(:base_url) => String.t(),
          required(:values) => %{String.t() => term()}
        }

  @typedoc """
  One query to ask: its origin, the variables its templates read, its GET URLs in path order,
  and the text `andmatch` compares rows with (nil for none).
  """
  @type planned :: %{
          origin: :id_scoped | :free_text,
          variables: Template.variables(),
          urls: [String.t()],
          andmatch: String.t() | nil
        }

  @doc """
  The queries one seam call asks, in order: `{:ok, entries}` with at least one, each
  `{:ok, planned}` or `{:error, reason}` for a query whose keyword filters or templates fail
  (`reason` `:regex_limit`, `:filter_output_cap`, or `:definition_error` for any other failure),
  so that query sends nothing and the others still run; or `{:not_asked, :caps}`.
  """
  @spec plan(map(), config(), Cinder.Acquisition.Indexer.query(), DateTime.t()) ::
          {:ok, [{:ok, planned()} | {:error, atom()}]} | {:not_asked, :caps}
  def plan(definition, config, query, now) do
    asks =
      for ask <- asks(definition, query),
          site_ids = site_categories(definition, ask.scope),
          site_ids != [],
          do: Map.put(ask, :site_ids, site_ids)

    case asks do
      [] -> {:not_asked, :caps}
      asks -> {:ok, Enum.map(asks, &planned(definition, config, &1, now))}
    end
  end

  @doc """
  The Test's request (#1657), as Prowlarr's `TestConnection` builds it: a keywordless search
  with no category, so `.Categories` holds the default site ids (none when no mapping is marked
  `default`) and no category rule leaves the indexer out. Answers
  `{:ok, url, variables}` for its first URL, or `{:error, reason}` as `plan/4` does.
  """
  @spec test_plan(map(), config(), DateTime.t()) ::
          {:ok, String.t(), Template.variables()} | {:error, atom()}
  def test_plan(definition, config, now) do
    ask = %{
      origin: :free_text,
      keywords: "",
      andmatch: nil,
      scope: [],
      values: %{},
      site_ids: default_site_ids(definition)
    }

    case planned(definition, config, ask, now) do
      {:ok, %{urls: [url | _], variables: variables}} -> {:ok, url, variables}
      {:ok, %{urls: []}} -> {:error, :definition_error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The standard category id of a `categorymappings` name, or nil for none."
  @spec category_id(String.t()) :: integer() | nil
  def category_id(name), do: Map.get(@category_ids, name)

  @doc """
  Every `{site_id, standard_id}` pair the definition maps, in file order: `caps.categories`
  first, then `caps.categorymappings`, each name read through `category_id/1`.
  """
  @spec mappings(map()) :: [{String.t(), integer()}]
  def mappings(definition) do
    pairs =
      Enum.map(definition.caps.categories, fn {id, cat} -> {id, cat} end) ++
        Enum.map(definition.caps.categorymappings, &{&1.id, &1.cat})

    for {id, cat} <- pairs, standard = category_id(cat), standard != nil, do: {id, standard}
  end

  # --- which queries ---

  # Each ask: origin, keywords, andmatch text, scope, and the `.Query.*` values it sets.
  defp asks(definition, {:search, imdb_id}) do
    with {:ok, digits} <- imdb_digits(imdb_id),
         true <- mode?(definition, "movie-search", "imdbid") do
      [
        id_scoped([@movie_category], %{
          "IMDBID" => "tt" <> digits,
          "IMDBIDShort" => digits
        })
      ]
    else
      _not_asked -> []
    end
  end

  defp asks(definition, {:search_tv, tvdb_id, title, season}) do
    id =
      if tvdb_id != nil and mode?(definition, "tv-search", "tvdbid"),
        do: [
          id_scoped([@tv_category], %{
            "TVDBID" => to_string(tvdb_id),
            "Season" => to_string(season)
          })
        ],
        else: []

    text =
      cond do
        mode?(definition, "tv-search", "q") and mode?(definition, "tv-search", "season") ->
          [
            free_text(title <> season_suffix(season), title, [@tv_category], %{
              "Season" => to_string(season)
            })
          ]

        mode?(definition, "search", "q") ->
          [free_text(title, title, [@tv_category], %{})]

        true ->
          []
      end

    id ++ text
  end

  defp asks(definition, {:search_movie_query, text, opts}),
    do: text_ask(definition, text, scope(opts, @movie_category))

  defp asks(definition, {:search_tv_query, text, opts}),
    do: text_ask(definition, text, scope(opts, @tv_category))

  defp asks(definition, {:search_ebook_query, text, opts}),
    do: text_ask(definition, text, scope(opts, @ebook_category))

  defp asks(definition, {:search_audiobook_query, text, opts}),
    do: text_ask(definition, text, scope(opts, @audiobook_category))

  defp asks(definition, {:search_ebook, author, title, opts}),
    do: book_ask(definition, author, title, scope(opts, @ebook_category))

  defp asks(definition, {:search_audiobook, author, title, opts}),
    do: book_ask(definition, author, title, scope(opts, @audiobook_category))

  defp text_ask(definition, text, scope) do
    if mode?(definition, "search", "q"), do: [free_text(text, text, scope, %{})], else: []
  end

  defp book_ask(definition, author, title, scope) do
    if mode?(definition, "book-search", "title") and
         (author == nil or mode?(definition, "book-search", "author")),
       do: [id_scoped(scope, %{"Title" => title, "Author" => author})],
       else: []
  end

  defp id_scoped(scope, values),
    do: %{origin: :id_scoped, keywords: "", andmatch: nil, scope: scope, values: values}

  defp free_text(keywords, andmatch, scope, values),
    do: %{
      origin: :free_text,
      keywords: keywords,
      andmatch: andmatch,
      scope: scope,
      values: Map.put(values, "Q", andmatch)
    }

  defp mode?(definition, mode, parameter) do
    case List.keyfind(definition.caps.modes, mode, 0) do
      {^mode, parameters} -> parameter in parameters
      nil -> false
    end
  end

  defp season_suffix(season) when is_integer(season) and season > 0,
    do: " S" <> String.pad_leading(Integer.to_string(season), 2, "0")

  defp season_suffix(_season), do: ""

  defp scope(opts, default) do
    case Keyword.get(opts, :categories) do
      [_ | _] = categories -> categories
      _none -> [default]
    end
  end

  defp imdb_digits(imdb_id) when is_binary(imdb_id) do
    case Regex.run(~r/\A(?:tt)?(\d+)\z/, imdb_id) do
      [_match, digits] -> {:ok, String.pad_leading(digits, 7, "0")}
      nil -> :error
    end
  end

  defp imdb_digits(_imdb_id), do: :error

  # --- one query ---

  defp planned(definition, config, ask, now) do
    base =
      definition
      |> Variables.blank()
      |> Map.merge(config_variables(definition, config))
      |> Map.merge(Map.new(ask.values, fn {name, value} -> {".Query." <> name, value} end))
      |> Map.merge(%{
        ".Query.Categories" => Enum.map(ask.scope, &Integer.to_string/1),
        ".Query.Keywords" => ask.keywords,
        ".Categories" => ask.site_ids
      })

    with {:ok, keywords} <- keywords(definition, ask.keywords, base, now),
         variables = Map.put(base, ".Keywords", keywords),
         {:ok, urls} <- urls(definition, config.base_url, variables, now) do
      {:ok,
       %{origin: ask.origin, variables: variables, urls: Enum.uniq(urls), andmatch: andmatch(ask)}}
    end
  end

  defp andmatch(%{andmatch: text}) when is_binary(text) and text != "", do: text
  defp andmatch(_ask), do: nil

  @doc """
  The site ids `scope` reaches in `definition`, each once in file order (see the moduledoc).
  """
  @spec site_categories(map(), [integer()]) :: [String.t()]
  def site_categories(definition, scope) do
    pairs = mappings(definition)
    reached = Caps.categories(%{"categories" => Enum.uniq(Enum.map(pairs, &elem(&1, 1)))}, scope)

    pairs
    |> Enum.filter(fn {_id, standard} -> standard in reached end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  defp default_site_ids(definition),
    do: for(%{default: true, id: id} <- definition.caps.categorymappings, uniq: true, do: id)

  @doc "The `.Config.*` variables of `config` for `definition` (see the moduledoc)."
  @spec config_variables(map(), config()) :: Template.variables()
  def config_variables(definition, config) do
    for setting <- definition.settings || [], into: %{".Config.sitelink" => config.base_url} do
      {".Config." <> setting.name, setting_value(setting, Map.get(config.values, setting.name))}
    end
  end

  defp setting_value(%{type: "checkbox"} = setting, nil),
    do: setting_value(setting, setting.default == "true")

  defp setting_value(%{type: "checkbox"}, value), do: if(value in [true, "true"], do: ".True")

  defp setting_value(%{type: type}, _value) when type not in ["select", "text", "password"],
    do: nil

  defp setting_value(%{type: "select"} = setting, nil), do: select_default(setting)
  defp setting_value(setting, nil), do: setting.default
  defp setting_value(_setting, value) when is_binary(value), do: value
  defp setting_value(_setting, _value), do: nil

  defp select_default(%{default: default}) when is_binary(default), do: default

  defp select_default(%{options: [{key, _label} | _]}), do: key
  defp select_default(_setting), do: nil

  defp keywords(definition, text, variables, now) do
    case Filters.apply(text, definition.search.keywordsfilters, variables, now) do
      {:ok, keywords} -> {:ok, keywords}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @doc "A filter or template error as the search reads it: a limit as itself, else `:definition_error`."
  @spec failure(term()) :: :regex_limit | :filter_output_cap | :definition_error
  def failure(:regex_limit), do: :regex_limit
  def failure(:filter_output_cap), do: :filter_output_cap
  def failure(_reason), do: :definition_error

  # --- the URLs ---

  defp urls(definition, base_url, variables, now) do
    Enum.reduce_while(definition.search.paths, {:ok, []}, fn path, {:ok, acc} ->
      case url(definition.search.inputs, path, base_url, variables, now) do
        {:ok, url} -> {:cont, {:ok, [url | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      error -> error
    end
  end

  defp url(search_inputs, path, base_url, variables, now) do
    with {:ok, rendered} <- render(path.path, variables, now, modifier: &encode/1),
         {:ok, inputs} <- inputs(search_inputs ++ path.inputs, variables, now),
         {:ok, uri} <- resolve(base_url, rendered) do
      {:ok, uri |> with_inputs(inputs) |> URI.to_string()}
    end
  end

  defp inputs(inputs, variables, now) do
    Enum.reduce_while(inputs, {:ok, []}, fn {key, template}, {:ok, acc} ->
      case render(template || "", variables, now) do
        {:ok, value} ->
          {:cont, {:ok, if(String.trim(value) == "", do: acc, else: [{key, value} | acc])}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp render(template, variables, now, opts \\ []) do
    case Template.render(template, variables, now, opts) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # Prowlarr's `WebUtility.UrlEncode`, then `+` as `%20`.
  defp encode(value), do: value |> URI.encode_www_form() |> String.replace("+", "%20")

  defp resolve(base_url, path) do
    with {:ok, base} <- URI.new(base_url || ""),
         true <- base.scheme in ["http", "https"] and is_binary(base.host),
         {:ok, _ref} <- URI.new(path) do
      {:ok, URI.merge(base, path)}
    else
      _invalid -> {:error, :definition_error}
    end
  end

  defp with_inputs(uri, []), do: uri

  defp with_inputs(uri, inputs) do
    query = URI.encode_query(inputs, :rfc3986)
    %{uri | query: if(uri.query in [nil, ""], do: query, else: uri.query <> "&" <> query)}
  end
end
