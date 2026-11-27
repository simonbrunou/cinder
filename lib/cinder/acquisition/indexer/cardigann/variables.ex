defmodule Cinder.Acquisition.Indexer.Cardigann.Variables do
  @moduledoc """
  The search variables a Cardigann template reads, by the names Prowlarr's
  `CardigannRequestGenerator` and `CardigannBase.GetBaseTemplateVariables` set (#1671, read at
  Prowlarr `b0b5774`): `.Config.sitelink`, `.Config.<name>` for each setting the definition
  declares, every `.Query.<name>` of `query_names/0`, `.Keywords` and `.Categories`.
  `Cinder.Acquisition.Indexer.Cardigann.Template` sets `.True`, `.False` and `.Today.Year`
  itself.

  `blank/1` holds every name with no value and `filled/1` every name with the text `x`, for the
  load check, which renders a selector template under both (`Cinder.Indexers.Definitions.
  LoadCheck`).
  """

  @query_names ~w(Type Q Series Movie Year Genre IMDBID IMDBIDShort TMDBID TraktID DoubanID
                  Album Artist Label Track Ep Season TVDBID TVRageID TVMazeID Episode Author
                  Title Publisher Categories Limit Offset Extended APIKey Keywords)

  @doc "The `.Query.<name>` names a search sets, without the prefix."
  @spec query_names() :: [String.t()]
  def query_names, do: @query_names

  @doc "Every search variable of `definition`, none with a value (`.Categories` empty)."
  @spec blank(map()) :: map()
  def blank(definition), do: all(definition, nil, [])

  @doc "Every search variable of `definition`, each the text `x` (`.Categories` `[\"x\"]`)."
  @spec filled(map()) :: map()
  def filled(definition), do: all(definition, "x", ["x"])

  defp all(definition, value, list) do
    query =
      Map.new(@query_names, fn
        "Categories" -> {".Query.Categories", list}
        name -> {".Query." <> name, value}
      end)

    config = Map.new(setting_names(definition), &{".Config." <> &1, value})

    query
    |> Map.merge(config)
    |> Map.merge(%{".Config.sitelink" => value, ".Keywords" => value, ".Categories" => list})
  end

  @doc """
  The `.DownloadUri.*` variables of a grab's link `uri` (#1672), as Prowlarr's
  `CardigannBase.AddTemplateVariablesFromUri` fills them from a .NET `Uri` (read at `b0b5774`):
  `.DownloadUri.AbsoluteUri` the link without its fragment, `.AbsolutePath` its path (`/` when
  it has none),
  `.Scheme`, `.Host`, `.Port` (the scheme's default when the link names none), `.PathAndQuery`,
  `.Query` (`?` and the query, or `""`), and `.DownloadUri.Query.<key>` for each query key,
  decoded, holding the first value given for it.
  """
  @spec download_uri(URI.t()) :: %{String.t() => String.t()}
  def download_uri(%URI{} = uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query

    keys =
      (uri.query || "")
      |> URI.query_decoder()
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put_new(acc, ".DownloadUri.Query." <> key, value)
      end)

    Map.merge(keys, %{
      ".DownloadUri.AbsoluteUri" => URI.to_string(%{uri | fragment: nil}),
      ".DownloadUri.AbsolutePath" => path,
      ".DownloadUri.Scheme" => uri.scheme,
      ".DownloadUri.Host" => uri.host,
      ".DownloadUri.Port" => Integer.to_string(uri.port || URI.default_port(uri.scheme) || -1),
      ".DownloadUri.PathAndQuery" => path <> query,
      ".DownloadUri.Query" => query
    })
  end

  @doc """
  The texts of a `download` block that can hold a template, in file order: each selector's
  `selector` and each of its filters' arguments that is a binary, then the same of `infohash`'s
  `hash` and `title`, then `before`'s `path` and each of its input values (#1679). `[]` for no
  block. The secret reference check reads them; the headers are not among them, since they go
  only to the definition's own hosts.
  """
  @spec download_texts(map() | nil) :: [String.t()]
  def download_texts(nil), do: []

  def download_texts(download) do
    infohash = download.infohash || %{}
    before = download.before || %{}

    blocks =
      download.selectors ++ Enum.reject([infohash[:hash], infohash[:title]], &is_nil/1)

    selector_texts =
      for block <- blocks,
          text <-
            [block.selector] ++
              for(filter <- block.filters || [], arg <- List.wrap(filter.args), do: arg),
          do: text

    before_texts = [before[:path] | for({_key, value} <- before[:inputs] || [], do: value)]

    Enum.filter(selector_texts ++ before_texts, &is_binary/1)
  end

  @doc """
  The texts a grab of `definition` renders: `download_texts/1`, then the first value of each
  header the grab sends (`download.headers` when the definition sets any, else
  `search.headers`). A grab names each `.DownloadUri.Query.<key>` they read.
  """
  @spec grab_texts(map()) :: [String.t()]
  def grab_texts(definition) do
    headers =
      case definition.download do
        %{headers: [_ | _] = headers} -> headers
        _none -> definition.search.headers || []
      end

    download_texts(definition.download) ++
      for {_name, [value | _]} <- headers, is_binary(value), do: value
  end

  @doc """
  The grab variables a download selector `template` of `definition` reads at load time, every
  one blank (`value` nil) or the text `x` (`value` `"x"`): the `.Config.*` variables, the
  `.DownloadUri.*` names of `download_uri/1`, and `.DownloadUri.Query.<key>` for each key the
  template names. The load check renders a download selector template under both.
  """
  @spec download(map(), String.t(), nil | String.t()) :: map()
  def download(definition, template, value) do
    named =
      ~r/\.DownloadUri\.Query\.([^\s{}()"]+)/
      |> Regex.scan(template, capture: :all_but_first)
      |> Map.new(fn [key] -> {".DownloadUri.Query." <> key, value} end)

    uri = Map.new(Map.keys(download_uri(URI.parse("http://x/"))), &{&1, value})
    config = Map.new(setting_names(definition), &{".Config." <> &1, value})

    named
    |> Map.merge(uri)
    |> Map.merge(config)
    |> Map.put(".Config.sitelink", value)
  end

  @doc "The names of the settings `definition` declares, in file order."
  @spec setting_names(map()) :: [String.t()]
  def setting_names(definition), do: for(%{name: name} <- definition.settings || [], do: name)
end
