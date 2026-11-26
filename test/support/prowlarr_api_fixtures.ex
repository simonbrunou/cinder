defmodule Cinder.ProwlarrApiFixtures do
  @moduledoc """
  Prowlarr API answers for the Prowlarr import's tests, decoded as `Cinder.Indexers.ProwlarrApi`
  returns them. Their keys follow what Prowlarr 3.1.0.5799 answered in a throwaway container on
  2026-11-26 (#1673): every top-level key of an `/api/v1/indexer` entry, and `fields` entries
  that leave out `value` when it is unset. A masked key answers `"********"`.

  `stub_api/3` makes `Cinder.Indexers.ProwlarrApiMock` answer the three reads the import makes.
  """
  import Mox

  @masked "********"

  def masked, do: @masked

  @doc "A generic Newznab indexer. `opts` override its top-level keys and field values."
  def newznab(id, opts \\ []), do: generic("Newznab", "usenet", id, opts)

  @doc "A generic Torznab indexer."
  def torznab(id, opts \\ []), do: generic("Torznab", "torrent", id, opts)

  defp generic(implementation, protocol, id, opts) do
    {fields, top} = Keyword.split(opts, [:base_url, :api_path, :api_key, :additional_parameters])

    fields =
      Keyword.merge(
        [
          base_url: "https://#{String.downcase(implementation)}#{id}.example",
          api_path: "/api",
          api_key: @masked,
          additional_parameters: nil
        ],
        fields
      )

    indexer(implementation, protocol, id, top, [
      field("baseUrl", fields[:base_url]),
      field("apiPath", fields[:api_path]),
      field("apiKey", fields[:api_key], "apiKey"),
      field("additionalParameters", fields[:additional_parameters]),
      field("vipExpiration", ""),
      field("baseSettings.queryLimit", nil),
      field("baseSettings.grabLimit", nil),
      field("baseSettings.limitsUnit", 0),
      field("baseSettings.queryTimeout", nil)
    ])
  end

  @doc """
  A Cardigann indexer for definition `definition`. `opts` override its top-level keys, and
  `:file` its `definitionFile` (default `definition`), `:base_url` its `baseUrl` (default unset)
  and `:fields` appends `fields` entries, such as a definition's settings.
  """
  def cardigann(id, definition, opts \\ []) do
    {file, opts} = Keyword.pop(opts, :file, definition)
    {base_url, opts} = Keyword.pop(opts, :base_url)

    indexer("Cardigann", "torrent", id, Keyword.put_new(opts, :definitionName, definition), [
      field("definitionFile", file),
      field("baseUrl", base_url),
      field("baseSettings.queryLimit", nil),
      field("torrentBaseSettings.seedRatio", nil)
    ])
  end

  @doc """
  A Cardigann `select` field as Prowlarr answers it: `selectOptions` numbers `labels` from 0, in
  the order given, and `value` is the stored position (left out when nil).
  """
  def select_field(name, position, labels) do
    name
    |> field(position)
    |> Map.merge(%{
      "type" => "select",
      "selectOptions" =>
        labels
        |> Enum.with_index()
        |> Enum.map(fn {label, i} -> %{"value" => i, "name" => label} end)
    })
  end

  @doc "A C# indexer, such as `BroadcastheNet`."
  def csharp(id, implementation, protocol \\ "torrent", opts \\ []) do
    indexer(implementation, protocol, id, opts, [
      field("baseUrl", nil),
      field("apiKey", @masked, "apiKey"),
      field("baseSettings.queryLimit", nil)
    ])
  end

  defp indexer(implementation, protocol, id, top, fields) do
    {extra_fields, top} = Keyword.pop(top, :fields, [])

    Map.merge(
      %{
        "indexerUrls" => [""],
        "legacyUrls" => [],
        "definitionName" => implementation,
        "description" => "#{implementation} indexer",
        "language" => "en-US",
        "encoding" => "Unicode (UTF-8)",
        "enable" => true,
        "redirect" => protocol == "usenet",
        "supportsRss" => true,
        "supportsSearch" => true,
        "supportsRedirect" => true,
        "supportsPagination" => true,
        "appProfileId" => 1,
        "protocol" => protocol,
        "privacy" => "private",
        "capabilities" => %{"categories" => [], "limitsMax" => 100, "limitsDefault" => 100},
        "priority" => 25,
        "downloadClientId" => 0,
        "added" => "2026-11-26T15:30:46Z",
        "sortName" => "indexer #{id}",
        "name" => "Indexer #{id}",
        "fields" => fields ++ extra_fields,
        "implementationName" => implementation,
        "implementation" => implementation,
        "configContract" => "#{implementation}Settings",
        "infoLink" => "https://wiki.servarr.com/prowlarr/supported-indexers",
        "tags" => [],
        "id" => id
      },
      Map.new(top, fn {key, value} -> {to_string(key), value} end)
    )
  end

  @doc "One `fields` entry; a nil `value` is left out, as Prowlarr leaves out an unset value."
  def field(name, value, privacy \\ "normal") do
    entry = %{
      "order" => 0,
      "name" => name,
      "label" => name,
      "type" => "textbox",
      "advanced" => false,
      "privacy" => privacy,
      "isFloat" => false
    }

    if is_nil(value), do: entry, else: Map.put(entry, "value", value)
  end

  @doc "An `/api/v1/indexerproxy` entry of `implementation` (FlareSolverr, Http, Socks4, Socks5)."
  def proxy(id, implementation, tags) do
    %{
      "onHealthIssue" => false,
      "supportsOnHealthIssue" => false,
      "includeHealthWarnings" => false,
      "name" => "#{implementation} #{id}",
      "fields" => [field("host", "proxy#{id}.example")],
      "implementationName" => implementation,
      "implementation" => implementation,
      "configContract" => "#{implementation}Settings",
      "infoLink" => "https://wiki.servarr.com/prowlarr/supported",
      "tags" => tags,
      "id" => id
    }
  end

  @doc """
  An `/api/v1/config/host` answer, shaped as Prowlarr's: it holds Prowlarr's own API key and the
  global proxy's password in clear.
  """
  def host(proxy_enabled?, api_key \\ "host-api-key-a81f", proxy_password \\ "host-proxy-pw-9c3e") do
    %{
      "allowedHosts" => [],
      "analyticsEnabled" => false,
      "apiKey" => api_key,
      "applicationUrl" => "",
      "authenticationMethod" => "forms",
      "authenticationRequired" => "enabled",
      "bindAddress" => "*",
      "branch" => "master",
      "id" => 1,
      "instanceName" => "Prowlarr",
      "password" => "",
      "port" => 9696,
      "proxyBypassFilter" => "",
      "proxyBypassLocalAddresses" => true,
      "proxyEnabled" => proxy_enabled?,
      "proxyHostname" => if(proxy_enabled?, do: "global.example", else: ""),
      "proxyPassword" => if(proxy_enabled?, do: proxy_password, else: ""),
      "proxyPort" => 8080,
      "proxyType" => "http",
      "proxyUsername" => "",
      "urlBase" => "",
      "username" => ""
    }
  end

  @doc """
  Makes `Cinder.Indexers.ProwlarrApiMock` answer `/api/v1/indexer`, `/api/v1/indexerproxy` and
  `/api/v1/config/host` with `indexers`, `proxies` and `host`, each a body or a `fun/0` returning
  the adapter's answer, `{:ok, body}` or `{:error, tag}`.
  """
  def stub_api(indexers, proxies \\ [], host \\ host(false)) do
    stub(Cinder.Indexers.ProwlarrApiMock, :get, fn _connection, path, [] ->
      case path do
        "/api/v1/indexer" -> answer(indexers)
        "/api/v1/indexerproxy" -> answer(proxies)
        "/api/v1/config/host" -> answer(host)
      end
    end)
  end

  defp answer(fun) when is_function(fun, 0), do: fun.()
  defp answer(body), do: {:ok, body}
end
