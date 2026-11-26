defmodule Cinder.Indexers.ProwlarrImport.Answer do
  @moduledoc """
  Reads the three Prowlarr answers the import uses into plain maps, refusing an answer whose
  shape it does not know as a whole with `{:error, :unexpected_response}`, never reading it as
  fewer indexers. It keeps only what the import reads.

  `/api/v1/indexer` is a list of indexers. Each holds an integer `id` above 0, no two alike,
  string `name`, `implementation` and `protocol` (`"usenet"`, `"torrent"` or `"unknown"`), a
  boolean `enable`, an integer `priority` and `appProfileId`, `tags` as a list of integers, and
  `fields` as a list of maps, each with a string `name`, no two alike, and a `value` that
  Prowlarr leaves out when it is unset. A Newznab or Torznab indexer also holds the `baseUrl`,
  `apiPath`, `apiKey` and `additionalParameters` fields, each with a string value or none. Each
  limit and seed field it reads (`@not_carried_fields`) holds a number or no value. A field
  `value` of JSON `null` reads as unset.

  A Cardigann indexer also holds a `definitionFile` field whose value is a non-empty string, the
  definition's file name without `.yml` as Prowlarr stores it (#1675), and a `baseUrl` field with
  a string value or none. A field's `selectOptions` reads as `{position, label}` pairs when it is
  a list of maps, each with an integer `value` and a string `name`; any other `selectOptions`
  reads as no options, as if Prowlarr named no label for the select. Such an indexer reads with
  `cardigann` set to a `Cinder.Indexers.ProwlarrImport.CardigannFields`: the file name, every
  field's value by name, and each select's options as `{position, label}` pairs. Its `fields` is
  empty, so its values show only in that struct, which `inspect` leaves out. Any other indexer
  reads without the `cardigann` key.

  `/api/v1/indexerproxy` is a list of proxies, each with an integer `id`, a string
  `implementation` and `tags` as a list of integers. `/api/v1/config/host` is a map whose
  `proxyEnabled` is a boolean; the rest of it, Prowlarr's own API key and the global proxy's
  password among it, is dropped.
  """

  alias Cinder.Indexers.ProwlarrImport.CardigannFields

  @generic ["Newznab", "Torznab"]
  @generic_fields ["baseUrl", "apiPath", "apiKey", "additionalParameters"]
  @protocols ["usenet", "torrent", "unknown"]

  # The Prowlarr settings the import does not carry, by the note a row lists when one is set.
  @not_carried_fields %{
    "baseSettings.queryLimit" => :query_limit,
    "baseSettings.grabLimit" => :grab_limit,
    "baseSettings.queryTimeout" => :query_timeout,
    "torrentBaseSettings.appMinimumSeeders" => :seed_settings,
    "torrentBaseSettings.seedRatio" => :seed_settings,
    "torrentBaseSettings.seedTime" => :seed_settings,
    "torrentBaseSettings.packSeedTime" => :seed_settings
  }

  @type indexer :: %{
          optional(:cardigann) => CardigannFields.t(),
          id: pos_integer(),
          name: String.t(),
          implementation: String.t(),
          protocol: String.t(),
          enable: boolean(),
          priority: integer(),
          tags: [integer()],
          app_profile_id: integer(),
          fields: %{optional(String.t()) => String.t() | nil},
          not_carried: [atom()]
        }

  @type proxy :: %{id: integer(), implementation: String.t(), tags: [integer()]}

  @doc "The indexers of an `/api/v1/indexer` body."
  @spec indexers(term()) :: {:ok, [indexer()]} | {:error, :unexpected_response}
  def indexers(body) when is_list(body) do
    with {:ok, indexers} <- all(body, &indexer/1),
         true <- unique?(indexers, & &1.id) do
      {:ok, indexers}
    else
      _ -> {:error, :unexpected_response}
    end
  end

  def indexers(_body), do: {:error, :unexpected_response}

  @doc "The proxies of an `/api/v1/indexerproxy` body."
  @spec proxies(term()) :: {:ok, [proxy()]} | {:error, :unexpected_response}
  def proxies(body) when is_list(body) do
    case all(body, &proxy/1) do
      {:ok, proxies} -> {:ok, proxies}
      :error -> {:error, :unexpected_response}
    end
  end

  def proxies(_body), do: {:error, :unexpected_response}

  @doc "Whether an `/api/v1/config/host` body has Prowlarr's global proxy on."
  @spec global_proxy(term()) :: {:ok, boolean()} | {:error, :unexpected_response}
  def global_proxy(%{"proxyEnabled" => enabled}) when is_boolean(enabled), do: {:ok, enabled}
  def global_proxy(_body), do: {:error, :unexpected_response}

  defp all(entries, read) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case read.(entry) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      :error -> :error
    end
  end

  defp indexer(%{
         "id" => id,
         "name" => name,
         "implementation" => implementation,
         "protocol" => protocol,
         "enable" => enable,
         "priority" => priority,
         "appProfileId" => app_profile_id,
         "tags" => tags,
         "fields" => entries
       })
       when is_integer(id) and id > 0 and is_binary(name) and is_binary(implementation) and
              protocol in @protocols and is_boolean(enable) and is_integer(priority) and
              is_integer(app_profile_id) and is_list(entries) do
    with true <- integers?(tags),
         {:ok, fields} <- fields(entries),
         true <- generic_fields?(implementation, fields),
         {:ok, cardigann} <- cardigann(implementation, fields, entries),
         {:ok, not_carried} <- not_carried(fields) do
      read = %{
        id: id,
        name: name,
        implementation: implementation,
        protocol: protocol,
        enable: enable,
        priority: priority,
        tags: tags,
        app_profile_id: app_profile_id,
        fields: Map.take(fields, @generic_fields),
        not_carried: not_carried
      }

      {:ok, Map.merge(read, cardigann)}
    else
      _ -> :error
    end
  end

  defp indexer(_entry), do: :error

  # Every field by name, with its value or nil when Prowlarr left it out.
  defp fields(entries) do
    with {:ok, pairs} <- all(entries, &field/1),
         true <- unique?(pairs, &elem(&1, 0)) do
      {:ok, Map.new(pairs)}
    else
      _ -> :error
    end
  end

  defp field(%{"name" => name} = entry) when is_binary(name),
    do: {:ok, {name, Map.get(entry, "value")}}

  defp field(_entry), do: :error

  # A Newznab or Torznab indexer names each field the import maps, each a string or unset.
  defp generic_fields?(implementation, fields) when implementation in @generic do
    Enum.all?(@generic_fields, fn name ->
      Map.has_key?(fields, name) and (is_nil(fields[name]) or is_binary(fields[name]))
    end)
  end

  defp generic_fields?(_implementation, _fields), do: true

  # A Cardigann indexer names its definition file and may hold a base URL; its selects carry
  # their options. The values stay raw: the definition the import pins gives each its type. Any
  # other indexer reads without the `cardigann` key.
  defp cardigann("Cardigann", fields, entries) do
    file = fields["definitionFile"]
    url = fields["baseUrl"]

    if is_binary(file) and file != "" and (is_nil(url) or is_binary(url)) do
      cardigann = %CardigannFields{
        file: file,
        values: fields,
        select_options: select_options(entries)
      }

      # Its values travel only in the struct, which `inspect` redacts.
      {:ok, %{cardigann: cardigann, fields: %{}}}
    else
      :error
    end
  end

  defp cardigann(_implementation, _fields, _entries), do: {:ok, %{}}

  # Prowlarr sends `selectOptions` on its own fields too; only a select's are read.
  defp select_options(entries) do
    for entry <- entries,
        {:ok, options} <- [options(Map.get(entry, "selectOptions"))],
        into: %{},
        do: {entry["name"], options}
  end

  defp options(list) when is_list(list) do
    all(list, fn
      %{"value" => value, "name" => name} when is_integer(value) and is_binary(name) ->
        {:ok, {value, name}}

      _option ->
        :error
    end)
  end

  defp options(_other), do: :error

  defp not_carried(fields) do
    Enum.reduce_while(@not_carried_fields, {:ok, []}, fn {name, note}, {:ok, notes} ->
      case Map.get(fields, name) do
        nil -> {:cont, {:ok, notes}}
        value when is_number(value) -> {:cont, {:ok, [note | notes]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, notes |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp proxy(%{"id" => id, "implementation" => implementation, "tags" => tags})
       when is_integer(id) and is_binary(implementation) do
    if integers?(tags),
      do: {:ok, %{id: id, implementation: implementation, tags: tags}},
      else: :error
  end

  defp proxy(_entry), do: :error

  defp integers?(list), do: is_list(list) and Enum.all?(list, &is_integer/1)

  defp unique?(items, key), do: length(Enum.uniq_by(items, key)) == length(items)
end
