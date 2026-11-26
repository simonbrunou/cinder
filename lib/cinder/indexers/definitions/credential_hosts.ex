defmodule Cinder.Indexers.Definitions.CredentialHosts do
  @moduledoc """
  The hosts a Cardigann configured indexer may send its credentials to (#1668; #1616 rule 5,
  #1620 point 10): `hosts/2` takes a loaded definition (`Cinder.Indexers.Definitions.Loader`)
  and the stored values (`stored_url`, the row's base URL, and `settings`, its plain and secret
  values by key), and answers a set of lowercased hosts.

  - The effective base URL (`effective_base_url/2`) is the stored one, unless it is nil, empty or
    listed in the definition's `legacylinks`; then it is the definition's first link, as in
    Prowlarr. Its host is in the set.
  - Each full `http://` or `https://` URL in a text the definition holds, setting defaults,
    `legacylinks` and `info` setting text included, adds its host. Its authority is the part
    after the scheme up to the first `/`, `?`, `#`, `\\`, quote, `<`, `>` or space outside a
    template. Its userinfo, up to the last `@` outside a template, is dropped before any fill,
    so a filled username or password never reaches the set.
  - The rest is then filled: each `{{ .Config.sitelink }}` with the effective base URL, each
    other `{{ .Config.<key> }}` with the stored value for `<key>`, over the definition's default
    for that setting when nothing is stored, or with nothing when neither exists. A `{{-` or
    `-}}` trim marker reads as `{{` or `}}`. The filled text up to the first of those same
    characters, with any userinfo, port and trailing dot dropped, is the host. A URL with no host
    adds nothing.
  - A host that still holds a template (`{{`) after the fill is unknown: it is in the set as
    `{:unknown, url}`, `url` being the raw scheme and authority with no userinfo and nothing
    filled, so it matches only the same raw text in another copy's set and holds no stored
    value.
  - A stored value or default that a `{{ .Config.<key> }}` reference names, `sitelink` aside,
    adds the host of each full URL it holds, so a setting whose value is a full URL adds its
    host. One whose host holds a template is in the set as `{:unknown, "{{ .Config.<key> }}"}`.
    A URL whose scheme comes from a filled value is not read.

  The Cardigann adapter's request path (`Cinder.Acquisition.Indexer.Cardigann.Fetch`, #1671)
  calls `hosts/2` at run time, as #1672's grab is to; the hold rules compare a candidate copy's
  set with the running copy's (`Cinder.Indexers.Definitions.Hold`).
  """

  @type host :: String.t() | {:unknown, String.t()}
  @type stored :: %{stored_url: String.t() | nil, settings: map()}

  @config ~r/\{\{-?\s*\.Config\.([A-Za-z0-9_-]+)\s*-?\}\}/
  @url ~r/https?:\/\/(?:\{\{.*?\}\}|[^\s\/?#\\"'<>{])*/i
  @template ~r/\{\{.*?\}\}/
  @stop ~r/[\s\/?#\\"'<>]/

  @doc "The hosts `definition` may send credentials to under the `stored` values."
  @spec hosts(map(), stored()) :: MapSet.t(host())
  def hosts(definition, %{stored_url: _, settings: settings} = stored) when is_map(settings) do
    base = effective_base_url(definition, stored.stored_url)
    values = values(definition, settings)

    definition
    |> texts([])
    |> Enum.flat_map(&(definition_hosts(&1, base, values) ++ value_hosts(&1, values)))
    |> Enum.concat(definition_hosts(base || "", nil, %{}))
    |> MapSet.new()
  end

  @doc """
  The base URL requests go to: the stored `base_url`, unless it is nil, empty or listed in the
  definition's `legacylinks`; then the first of its `links`.
  """
  @spec effective_base_url(map(), String.t() | nil) :: String.t() | nil
  def effective_base_url(definition, base_url) do
    if base_url in [nil, ""] or base_url in (definition.legacylinks || []),
      do: List.first(definition.links || []),
      else: base_url
  end

  # Every stored value, over each declared setting's default, as text.
  defp values(definition, settings) do
    defaults =
      for %{name: name, default: default} <- definition.settings || [],
          is_binary(name) and is_binary(default),
          into: %{},
          do: {name, default}

    defaults
    |> Map.merge(settings)
    |> Map.new(fn {key, value} -> {key, text(value)} end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(true), do: "true"
  defp text(false), do: "false"
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  # Every binary in the definition, map and tuple keys included, in no set order.
  defp texts(value, acc) when is_binary(value), do: [value | acc]

  defp texts(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {k, v}, acc -> texts(v, texts(k, acc)) end)

  defp texts(list, acc) when is_list(list), do: Enum.reduce(list, acc, &texts/2)
  defp texts(tuple, acc) when is_tuple(tuple), do: texts(Tuple.to_list(tuple), acc)
  defp texts(_other, acc), do: acc

  defp fill(text, base, values) do
    Regex.replace(@config, text, fn
      _whole, "sitelink" -> base || ""
      _whole, key -> Map.get(values, key, "")
    end)
  end

  # The URLs of the raw text: userinfo dropped, then the rest filled.
  defp definition_hosts(text, base, values) do
    for [url] <- Regex.scan(@url, text),
        host = definition_host(url, base, values),
        host != nil,
        do: host
  end

  defp definition_host(url, base, values) do
    [scheme, authority] = String.split(url, "://", parts: 2)
    raw = after_userinfo(authority)
    filled = fill(raw, base, values)

    if String.contains?(filled, "{{"),
      do: {:unknown, scheme <> "://" <> raw},
      else: filled |> String.split(@stop, parts: 2) |> hd() |> literal_host()
  end

  # The URLs a referenced stored value or default holds on its own.
  defp value_hosts(text, values) do
    for [_whole, key] <- Regex.scan(@config, text),
        key != "sitelink",
        [url] <- Regex.scan(@url, Map.get(values, key, "")),
        host = value_host(url, key),
        host != nil,
        do: host
  end

  defp value_host(url, key) do
    [_scheme, authority] = String.split(url, "://", parts: 2)

    if String.contains?(authority, "{{"),
      do: {:unknown, "{{ .Config.#{key} }}"},
      else: literal_host(authority)
  end

  defp literal_host(authority), do: authority |> strip_userinfo() |> strip_port() |> normal()

  # The authority after its last `@` outside a template.
  defp after_userinfo(authority) do
    parts = Regex.split(@template, authority, include_captures: true)

    parts
    |> Enum.with_index()
    |> Enum.filter(fn {part, _at} -> not template?(part) and String.contains?(part, "@") end)
    |> List.last()
    |> case do
      nil -> authority
      {part, at} -> strip_userinfo(part) <> Enum.join(Enum.drop(parts, at + 1))
    end
  end

  defp template?(part), do: String.starts_with?(part, "{{")

  defp strip_userinfo(authority),
    do: authority |> String.split("@") |> List.last()

  defp strip_port("[" <> _ = authority) do
    case String.split(authority, "]", parts: 2) do
      [inside, _port] -> inside <> "]"
      [_unclosed] -> authority
    end
  end

  defp strip_port(authority) do
    case String.split(authority, ":") do
      [host] -> host
      [host, port] -> if port =~ ~r/\A[0-9]*\z/, do: host, else: authority
      _several -> authority
    end
  end

  defp normal(host) do
    case host |> String.trim_trailing(".") |> String.downcase() do
      "" -> nil
      host -> host
    end
  end
end
