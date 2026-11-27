defmodule Cinder.Acquisition.Indexer.Cardigann.JsonPath do
  @moduledoc ~S"""
  The JSON paths and selector chains of a Cardigann JSON search (#1678), read as Prowlarr's
  `CardigannBase.JsonParseRowsSelector` and `JsonParseFieldSelector` read them with
  Newtonsoft's `SelectToken` (`b0b5774`). Pure.

  ## Paths

  A path is one of the shapes the v11 definitions use: empty (the value itself), `$` (the
  same), `key`, `a.b`, `a[0].b`, `$.key` and `$[0].id`. A name is any run of characters other
  than `.`, `[`, `]`, `(`, `)`, `'`, `"`, `*`, `?`, `@`, `$`, `:`, `,` and white space, and an
  index is decimal digits. Any other syntax, such as a wildcard, a filter expression, a
  recursive descent or a quoted name, is `:error` from `parse/1`, which the load check reports
  as `{:json, :path}`. `select/2` answers `{:ok, value}`, a JSON `null` included, or `:none`
  where `SelectToken` gives nothing: a missing key, an index past the end, a key on a value that
  is not an object or an index on one that is not an array.

  ## Selector chains

  A rows or field selector is a path, cut at its first `:`, then any chain of `:has(<key>)`,
  `:not(<key>)` and `:contains(<text>)`, found with Prowlarr's pattern
  `\:(?<filter>.+?)\((?<key>.+?)\)(?=:|\z)`. `:has` keeps the value when its key selects
  something, `:not` when it selects nothing, and a key that holds the pattern itself is a chain
  of its own (`:not(a:contains(x))`). `:contains` keeps the value when its text
  (`Cinder.Acquisition.Indexer.Cardigann.JsonText.text/1`) holds the text as written, quotes
  included. `chain/1` refuses, as `:error`, a selector whose path does not parse, any other
  pseudo-class, a key that does not parse, and text the pattern does not cover, where Prowlarr
  ignores the rest of the selector.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.JsonText

  @filter ~r/\:(?<filter>.+?)\((?<key>.+?)\)(?=:|\z)/
  @name ~r/\A[^.\[\]()'"*?@$:,\s]+/u
  @index ~r/\A\[(\d{1,9})\]/

  @type step :: {:key, String.t()} | {:index, non_neg_integer()}
  @type chain :: %{
          path: [step()],
          filters: [{:has | :not, chain() | [step()]} | {:contains, String.t()}]
        }

  # Newtonsoft.Json 13.0.4's `JToken.Parse` throws on a 65th nested object or array (its
  # reader's `MaxDepth` of 64). The cap also bounds the indent `JsonText.text/1` writes before
  # each item, but not the text's size: a 2,080,127-byte body of one-digit items 63 arrays deep
  # prints 134,168,191 bytes (#1678's re-check). The search processes' heap cap kills that
  # build, and `JsonText.join/3` counts its size before building it.
  @max_depth 64

  @doc """
  `text` decoded with `Jason.decode/2`, objects in order, or `:error`. A key an object holds
  twice keeps its first place and its last value, as Newtonsoft's `JObject` does. A value that
  nests more than #{@max_depth} objects and arrays is `:error`, as `JToken.Parse` throws on it.
  """
  @spec decode(String.t()) :: {:ok, term()} | :error
  def decode(text) when is_binary(text) do
    with {:ok, value} <- Jason.decode(text, objects: :ordered_objects),
         true <- within_depth?(value, @max_depth) do
      {:ok, last_keys(value)}
    else
      _refused -> :error
    end
  end

  defp within_depth?(%Jason.OrderedObject{values: pairs}, left),
    do: left > 0 and Enum.all?(pairs, fn {_key, value} -> within_depth?(value, left - 1) end)

  defp within_depth?(list, left) when is_list(list),
    do: left > 0 and Enum.all?(list, &within_depth?(&1, left - 1))

  defp within_depth?(_scalar, _left), do: true

  defp last_keys(%Jason.OrderedObject{values: pairs}) do
    last = Map.new(pairs)

    kept =
      pairs
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.map(&{&1, last_keys(Map.fetch!(last, &1))})

    %Jason.OrderedObject{values: kept}
  end

  defp last_keys(list) when is_list(list), do: Enum.map(list, &last_keys/1)
  defp last_keys(value), do: value

  @doc "The steps of `path`, or `:error` for a shape outside the moduledoc's list."
  @spec parse(String.t()) :: {:ok, [step()]} | :error
  def parse(""), do: {:ok, []}
  def parse("$"), do: {:ok, []}
  def parse("$." <> rest) when rest != "", do: segments(rest)
  def parse("$[" <> _ = path), do: path |> binary_part(1, byte_size(path) - 1) |> indexed()
  def parse(path) when is_binary(path), do: segments(path)

  defp indexed(text) do
    case indexes(text, []) do
      {:ok, steps, ""} ->
        {:ok, steps}

      {:ok, steps, "." <> rest} when rest != "" ->
        with {:ok, more} <- segments(rest), do: {:ok, steps ++ more}

      _other ->
        :error
    end
  end

  defp segments(text) do
    text
    |> String.split(".")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case segment(part) do
        {:ok, steps} -> {:cont, {:ok, acc ++ steps}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp segment(part) do
    with [name] <- Regex.run(@name, part),
         rest = binary_part(part, byte_size(name), byte_size(part) - byte_size(name)),
         {:ok, steps, ""} <- indexes(rest, []) do
      {:ok, [{:key, name} | steps]}
    else
      _other -> :error
    end
  end

  defp indexes(text, acc) do
    case Regex.run(@index, text) do
      [whole, digits] ->
        rest = binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))
        indexes(rest, [{:index, String.to_integer(digits)} | acc])

      nil ->
        {:ok, Enum.reverse(acc), text}
    end
  end

  @doc "The value `steps` select in `value`; see the moduledoc."
  @spec select(term(), [step()]) :: {:ok, term()} | :none
  def select(value, []), do: {:ok, value}

  def select(%Jason.OrderedObject{values: pairs}, [{:key, key} | rest]) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> select(value, rest)
      nil -> :none
    end
  end

  def select(list, [{:index, n} | rest]) when is_list(list) do
    case Enum.fetch(list, n) do
      {:ok, value} -> select(value, rest)
      :error -> :none
    end
  end

  def select(_value, _steps), do: :none

  @doc "The chain `selector` holds, or `:error`; see the moduledoc."
  @spec chain(String.t()) :: {:ok, chain()} | :error
  def chain(selector) when is_binary(selector) do
    [path_text | _] = String.split(selector, ":", parts: 2)
    matches = Regex.scan(@filter, selector, capture: :all)

    with true <- path_text <> Enum.map_join(matches, &hd/1) == selector,
         {:ok, path} <- parse(path_text),
         {:ok, filters} <- filters(matches) do
      {:ok, %{path: path, filters: filters}}
    else
      _invalid -> :error
    end
  end

  defp filters(matches) do
    Enum.reduce_while(matches, {:ok, []}, fn [_whole, name, key], {:ok, acc} ->
      case filter(name, key) do
        {:ok, filter} -> {:cont, {:ok, acc ++ [filter]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp filter("contains", text), do: {:ok, {:contains, text}}

  defp filter(name, key) when name in ["has", "not"] do
    tag = String.to_existing_atom(name)

    if Regex.match?(@filter, key) do
      with {:ok, inner} <- chain(key), do: {:ok, {tag, inner}}
    else
      with {:ok, steps} <- parse(key), do: {:ok, {tag, steps}}
    end
  end

  defp filter(_name, _key), do: :error

  @doc """
  `JsonParseFieldSelector`: the steps of `chain`'s path when `value` passes its filters, else
  `:none`.
  """
  @spec field(term(), chain()) :: {:ok, [step()]} | :none
  def field(value, %{path: path, filters: filters}) do
    with {:ok, base} <- select(value, path),
         true <- Enum.all?(filters, &passes?(base, &1)) do
      {:ok, path}
    else
      _no -> :none
    end
  end

  defp passes?(base, {:has, inner}), do: found?(base, inner)
  defp passes?(base, {:not, inner}), do: not found?(base, inner)
  defp passes?(base, {:contains, text}), do: String.contains?(JsonText.text(base), text)

  defp found?(base, %{} = inner), do: field(base, inner) != :none
  defp found?(base, steps), do: select(base, steps) != :none

  @doc """
  `JsonParseRowsSelector`: the objects of the array `chain`'s path selects in `root` that pass
  its filters, or `:error` when the path selects nothing, something that is not an array, or an
  array that holds a value that is not an object.
  """
  @spec rows(term(), chain()) :: {:ok, [Jason.OrderedObject.t()]} | :error
  def rows(root, %{path: path, filters: filters}) do
    with {:ok, list} when is_list(list) <- select(root, path),
         true <- Enum.all?(list, &match?(%Jason.OrderedObject{}, &1)) do
      {:ok, Enum.filter(list, &(field(&1, %{path: [], filters: filters}) != :none))}
    else
      _no -> :error
    end
  end
end
