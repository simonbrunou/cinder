defmodule Cinder.Acquisition.Indexer.Cardigann.Jar do
  @moduledoc """
  The cookies a Cardigann request chain keeps (#1672, #1680): by origin (scheme, host in lower
  case without a trailing dot, port), each origin's cookies by name, and the fixed cookies a
  login gives (the `cookie` method's setting, `login.cookies`), by name, for every credential
  host.

  - `keep/3` keeps a `Set-Cookie`'s `name=value` pair only from a credential host, when its name
    is not blank, the pair is under 4 KiB, and neither holds a control character, a `;` or a
    `,`. An origin keeps at most 32 names: a new name past them is dropped, a known one replaced.
    Any other host's `Set-Cookie` is dropped.
  - `header/3` sends an origin's cookies back only to that same origin, and only while its host
    is a credential host: a definition update that drops a host leaves that host's stored
    cookies unsent.
  - `put_string/3` adds a cookie string under one origin, by the same pair rules.
  - `put_fixed/2` adds a cookie string as fixed cookies, by the same pair rules: `header/3`
    sends them to every credential host, on any scheme and port, and a cookie of the same name
    that the request's own origin set wins.

  `inspect/1` shows no cookie: a crash report that prints a jar prints its origin count only.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.Fetch

  @max_cookies 32
  @max_cookie_bytes 4_096

  @derive {Inspect, only: []}
  defstruct cookies: %{}, fixed: %{}

  @type origin :: {String.t(), String.t(), non_neg_integer() | nil}
  @type t :: %__MODULE__{
          cookies: %{origin() => %{String.t() => String.t()}},
          fixed: %{String.t() => String.t()}
        }

  @doc "An empty jar."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether the jar holds no cookie."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{cookies: cookies, fixed: fixed}),
    do: map_size(fixed) == 0 and Enum.all?(cookies, &(map_size(elem(&1, 1)) == 0))

  @doc "The origin of `uri`, as the jar keys it."
  @spec origin(URI.t()) :: origin()
  def origin(%URI{scheme: scheme, host: host, port: port}),
    do: {scheme, host |> String.downcase(:ascii) |> String.trim_trailing("."), port}

  @doc """
  `jar` with the `Set-Cookie` pairs of `response`, which `uri` answered, kept when `uri`'s host is
  one of `hosts`; see the moduledoc.
  """
  @spec keep(t(), URI.t(), Req.Response.t(), MapSet.t()) :: t()
  def keep(%__MODULE__{} = jar, %URI{} = uri, %Req.Response{} = response, hosts) do
    if Fetch.credential_host?(uri, hosts) do
      response
      |> Req.Response.get_header("set-cookie")
      |> Enum.flat_map(&set_cookie_pair/1)
      |> Enum.reduce(jar, &put_pair(&2, origin(uri), &1))
    else
      jar
    end
  end

  @doc """
  `jar` with each `name=value` pair of `text`, a cookie string such as `a=1; b=2`, as fixed
  cookies, by the moduledoc's pair rules. A part that is not such a pair is left out.
  """
  @spec put_fixed(t(), String.t()) :: t()
  def put_fixed(%__MODULE__{fixed: fixed} = jar, text) when is_binary(text) do
    pairs = text |> String.split(";") |> Enum.flat_map(&pair/1)
    %{jar | fixed: Enum.reduce(pairs, fixed, &put_named(&2, &1))}
  end

  @doc """
  `jar` with each `name=value` pair of `text`, a cookie string such as `a=1; b=2`, under the
  origin of `uri`, by the moduledoc's pair rules. A part that is not such a pair is left out.
  """
  @spec put_string(t(), URI.t(), String.t()) :: t()
  def put_string(%__MODULE__{} = jar, %URI{} = uri, text) when is_binary(text) do
    text
    |> String.split(";")
    |> Enum.flat_map(&pair/1)
    |> Enum.reduce(jar, &put_pair(&2, origin(uri), &1))
  end

  @doc """
  The `cookie` header for a request to `uri`: the fixed cookies and the cookies of `uri`'s
  origin, the origin's winning on a name, when its host is one of `hosts`, else none.
  """
  @spec header(t(), URI.t(), MapSet.t()) :: [{String.t(), String.t()}]
  def header(%__MODULE__{cookies: cookies, fixed: fixed}, %URI{} = uri, hosts) do
    with true <- Fetch.credential_host?(uri, hosts),
         found when map_size(found) > 0 <- Map.merge(fixed, Map.get(cookies, origin(uri), %{})) do
      [{"cookie", Enum.map_join(found, "; ", fn {name, value} -> "#{name}=#{value}" end)}]
    else
      _none -> []
    end
  end

  @doc """
  The jar as a list for storage: each fixed cookie as `[name, value]`, then each origin's as
  `[scheme, host, port, name, value]`.
  """
  @spec to_list(t()) :: [list()]
  def to_list(%__MODULE__{cookies: cookies, fixed: fixed}) do
    fixed = for {name, value} <- Enum.sort(fixed), do: [name, value]

    fixed ++
      for {{scheme, host, port}, found} <- Enum.sort(cookies),
          {name, value} <- Enum.sort(found),
          do: [scheme, host, port, name, value]
  end

  @doc """
  The jar `to_list/1` stored, or `:error` when an entry is not such a list of texts and a port.
  """
  @spec from_list(term()) :: {:ok, t()} | :error
  def from_list(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, new()}, fn
      [scheme, host, port, name, value], {:ok, jar}
      when is_binary(scheme) and is_binary(host) and (is_integer(port) or is_nil(port)) and
             is_binary(name) and is_binary(value) ->
        {:cont, {:ok, put_pair(jar, {scheme, host, port}, {name, value})}}

      [name, value], {:ok, jar} when is_binary(name) and is_binary(value) ->
        {:cont, {:ok, %{jar | fixed: put_named(jar.fixed, {name, value})}}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  def from_list(_entries), do: :error

  defp put_pair(%__MODULE__{cookies: cookies} = jar, origin, pair),
    do: %{jar | cookies: Map.put(cookies, origin, put_named(Map.get(cookies, origin, %{}), pair))}

  # Past `@max_cookies` names, a new name is dropped; a known one is replaced.
  defp put_named(found, {name, value}) do
    if map_size(found) < @max_cookies or Map.has_key?(found, name),
      do: Map.put(found, name, value),
      else: found
  end

  # The `name=value` pair before a `Set-Cookie`'s first `;`.
  defp set_cookie_pair(header) do
    case String.split(header, ";", parts: 2) do
      [pair | _attributes] -> pair(pair)
      _none -> []
    end
  end

  @doc """
  Whether `name` and `value` make a cookie the jar keeps, by the moduledoc's pair rules: a name
  that is not blank, no control character, `;` or `,` in either, under 4 KiB together. Names and
  values are not trimmed here.
  """
  @spec cookie?(term(), term()) :: boolean()
  def cookie?(name, value) when is_binary(name) and is_binary(value),
    do: pair(name <> "=" <> value) == [{name, value}]

  def cookie?(_name, _value), do: false

  # A pair kept when its name is not blank and neither holds a control character, a `;` or a
  # `,`, and it fits `@max_cookie_bytes`.
  defp pair(pair) do
    with [name, value] <- String.split(pair, "=", parts: 2),
         name = String.trim(name),
         value = String.trim(value),
         true <- name != "" and byte_size(name) + byte_size(value) < @max_cookie_bytes,
         true <- cookie_text?(name) and cookie_text?(value) do
      [{name, value}]
    else
      _refused -> []
    end
  end

  defp cookie_text?(text),
    do: String.valid?(text) and not String.match?(text, ~r/[\x00-\x1f\x7f;,]/)
end
