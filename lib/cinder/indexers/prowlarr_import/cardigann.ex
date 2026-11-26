defmodule Cinder.Indexers.ProwlarrImport.Cardigann do
  @moduledoc """
  Maps one Prowlarr Cardigann indexer to a native Cardigann configured indexer for the Prowlarr
  import (#1675, the #1622 resolution's points 8 and 9). `Cinder.Indexers.ProwlarrImport` calls
  `plan/3` with the indexer as `Cinder.Indexers.ProwlarrImport.Answer` reads it, the mirror copy
  `Cinder.Indexers.Definitions.import_copy/1` answers for its file, and the proxy outcomes of its
  tags. The answer is one of:

    * `:held`: no definition set was ever loaded, or the mirror's copy has no load result under
      the current fingerprint yet, which the boot re-check gives it: a through-Prowlarr import
      would link the indexer for good;
    * `{:via_prowlarr, reasons}`: it cannot go direct, each reason a code the dialog words:
      `:definition_not_available` (removed upstream, not in the mirror, replaced by another file,
      or a copy that fails to load), `:needs_newer_cinder`,
      `{:not_supported, feature}` for each feature the copy's load result names,
      `:base_url_not_in_links`, `{:select_no_default, label}`, and the proxy codes
      `:http_proxy`, `:socks_proxy`, `:other_proxy` and `:global_proxy`;
    * `{:direct, plan}`: `attrs` for `Cinder.Indexers.create_imported/4`, the secret field names
      Prowlarr answered in clear (`clear`) and masked (`masked`, with each one's label), and
      `notes`, `{:took_default, label}` for each select that took its default.

  The file is Prowlarr's `definitionFile` with `.yml` added, unless it already ends in `.yml`.

  Base URL: Prowlarr's stored URL, unless it is blank or one of the copy's legacy links, compared
  with any trailing `/` cut; then the copy's first link. A URL that matches a link that way takes
  the link as the copy writes it, since the create checks the URL against the links as written.
  Any other URL is `:base_url_not_in_links`.

  Settings, read against the copy: a `checkbox` takes Prowlarr's boolean; a `text` or `password`
  setting is a secret, `masked` when Prowlarr answers `********`, `clear` for any other non-blank
  text, and left out when blank. A `select` reads Prowlarr's stored position as the label
  Prowlarr's `selectOptions` gives it. When that label is Prowlarr's only option with it and
  the copy's only option with it, the select stores the copy's key. Otherwise it takes the copy's
  default with `{:took_default, label}`, or, with no default, `{:select_no_default, label}`. A
  select Prowlarr holds no value for takes the copy's default with no note, as Prowlarr does, or
  with no default is `{:select_no_default, label}`. Any other setting Prowlarr gives no value of
  the right kind takes the copy's default. `label` is the
  setting's label from the copy, or its name when the copy has none.

  A FlareSolverr proxy sharing a tag turns the FlareSolverr toggle on of an indexer that goes
  direct. A through-Prowlarr row has no toggle: Prowlarr keeps its own proxies.
  """

  @masked "********"
  @secret_types ["text", "password"]
  @proxy_codes [:http_proxy, :socks_proxy, :other_proxy, :global_proxy]

  @type reason ::
          :definition_not_available
          | :needs_newer_cinder
          | {:not_supported, term()}
          | :base_url_not_in_links
          | {:select_no_default, String.t()}
          | :http_proxy
          | :socks_proxy
          | :other_proxy
          | :global_proxy

  @type plan :: %{
          attrs: map(),
          clear: [String.t()],
          masked: [%{field: String.t(), label: String.t()}],
          notes: [{:took_default, String.t()}]
        }

  @doc "The file name the mirror keys Prowlarr's `definitionFile` under."
  @spec file_name(String.t()) :: String.t()
  def file_name(file) do
    if String.ends_with?(file, ".yml"), do: file, else: file <> ".yml"
  end

  @doc """
  The plan of one Cardigann `indexer`, given its mirror `copy` and its proxy outcomes `proxies`
  (`:flaresolverr` and the codes of `t:reason/0` that name a proxy), as the moduledoc says.
  """
  @spec plan(map(), Cinder.Indexers.Definitions.import_copy(), [atom()]) ::
          :held | {:via_prowlarr, [reason()]} | {:direct, plan()}
  def plan(_indexer, :never_loaded, _proxies), do: :held
  def plan(_indexer, {:in_mirror, %{result: :unchecked}}, _proxies), do: :held

  def plan(indexer, copy, proxies) do
    proxy_reasons = Enum.filter(proxies, &(&1 in @proxy_codes))

    case copy_reasons(indexer, copy) do
      {:ok, definition, blob_sha} when proxy_reasons == [] ->
        direct(indexer, definition, blob_sha, :flaresolverr in proxies)

      {:ok, _definition, _blob_sha} ->
        {:via_prowlarr, sorted(proxy_reasons)}

      {:via, reasons} ->
        {:via_prowlarr, sorted(reasons ++ proxy_reasons)}
    end
  end

  defp sorted(reasons), do: reasons |> Enum.uniq() |> Enum.sort()

  # The copy's own reasons to go through Prowlarr, or its usable definition.
  defp copy_reasons(_indexer, :unavailable), do: {:via, [:definition_not_available]}
  defp copy_reasons(_indexer, :needs_newer_cinder), do: {:via, [:needs_newer_cinder]}

  defp copy_reasons(indexer, {:in_mirror, %{definition: definition} = copy})
       when is_map(definition) do
    case copy.result do
      :loads -> loads(indexer, definition, copy.blob_sha)
      {:not_supported, codes} -> {:via, Enum.map(codes, &{:not_supported, &1})}
      {:fails, _reason} -> {:via, [:definition_not_available]}
    end
  end

  defp copy_reasons(_indexer, {:in_mirror, _no_definition}),
    do: {:via, [:definition_not_available]}

  defp loads(indexer, definition, blob_sha) do
    url_reasons =
      case base_url(indexer.cardigann.values["baseUrl"], definition) do
        {:ok, _url} -> []
        :error -> [:base_url_not_in_links]
      end

    select_reasons =
      for setting <- settings(definition, ["select"]),
          {:no_default, label} <- [select(indexer, setting)],
          do: {:select_no_default, label}

    case url_reasons ++ select_reasons do
      [] -> {:ok, definition, blob_sha}
      reasons -> {:via, reasons}
    end
  end

  defp direct(indexer, definition, blob_sha, flaresolverr?) do
    {:ok, url} = base_url(indexer.cardigann.values["baseUrl"], definition)
    values = indexer.cardigann.values

    {plain, notes} =
      Enum.reduce(settings(definition, ["checkbox", "select"]), {%{}, []}, fn setting,
                                                                              {plain, notes} ->
        case plain_value(indexer, setting) do
          {:ok, value} -> {Map.put(plain, setting.name, value), notes}
          {:default, label} -> {plain, [{:took_default, label} | notes]}
          :default -> {plain, notes}
        end
      end)

    secrets = settings(definition, @secret_types)

    {:direct,
     %{
       attrs: %{
         "type" => :cardigann,
         "definition" => file_name(indexer.cardigann.file),
         "definition_blob_sha" => blob_sha,
         "base_url" => url,
         "enabled" => indexer.enable,
         "priority" => indexer.priority,
         "flaresolverr" => flaresolverr?,
         "settings" => plain
       },
       clear: for(s <- secrets, clear?(values[s.name]), do: s.name),
       masked:
         for(s <- secrets, values[s.name] == @masked, do: %{field: s.name, label: label(s)}),
       notes: Enum.reverse(notes)
     }}
  end

  defp clear?(value), do: is_binary(value) and value != @masked and String.trim(value) != ""

  defp plain_value(indexer, %{type: "checkbox"} = setting) do
    case indexer.cardigann.values[setting.name] do
      value when is_boolean(value) -> {:ok, value}
      _other -> :default
    end
  end

  defp plain_value(indexer, %{type: "select"} = setting) do
    select(indexer, setting)
  end

  # The copy's key for the label Prowlarr's stored position names, when that label is unique on
  # both sides; else the copy's default, or none.
  defp select(indexer, setting) do
    prowlarr = Map.get(indexer.cardigann.select_options, setting.name, [])
    position = indexer.cardigann.values[setting.name]
    label = Enum.find_value(prowlarr, fn {value, name} -> if value == position, do: name end)

    case unique_key(prowlarr, label, setting) do
      {:ok, key} -> {:ok, key}
      :error -> fallback(position, setting)
    end
  end

  defp unique_key(prowlarr, label, setting) when is_binary(label) do
    keys = for {key, name} <- setting.options || [], name == label, do: key

    if Enum.count(prowlarr, &(elem(&1, 1) == label)) == 1 and length(keys) == 1,
      do: {:ok, hd(keys)},
      else: :error
  end

  defp unique_key(_prowlarr, _label, _setting), do: :error

  defp fallback(nil, %{default: default}) when is_binary(default), do: :default

  defp fallback(_position, %{default: default} = setting) when is_binary(default),
    do: {:default, label(setting)}

  defp fallback(_position, setting), do: {:no_default, label(setting)}

  defp label(%{label: label}) when is_binary(label) and label != "", do: label
  defp label(setting), do: setting.name

  defp settings(definition, types),
    do: for(%{type: type} = setting <- definition.settings || [], type in types, do: setting)

  @doc """
  The base URL Prowlarr searches for a stored `url`, against the copy's links, as the moduledoc
  says: `{:ok, link}` or `:error`.
  """
  @spec base_url(term(), map()) :: {:ok, String.t()} | :error
  def base_url(url, definition) do
    links = definition.links || []
    legacy = Enum.map(definition.legacylinks || [], &trimmed/1)

    cond do
      not is_binary(url) or String.trim(url) == "" or trimmed(url) in legacy -> first(links)
      link = Enum.find(links, &(trimmed(&1) == trimmed(url))) -> {:ok, link}
      true -> :error
    end
  end

  defp first([link | _rest]), do: {:ok, link}
  defp first([]), do: :error

  defp trimmed(url), do: String.trim_trailing(url, "/")
end
