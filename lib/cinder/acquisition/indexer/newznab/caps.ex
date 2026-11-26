defmodule Cinder.Acquisition.Indexer.Newznab.Caps do
  @moduledoc """
  A Newznab or Torznab indexer's `t=caps` answer, parsed (#1652). The parsed caps are a plain map
  with string keys, the same before and after a JSON round trip, so
  `Cinder.Acquisition.IndexerSource.Native.IndexerCaps` stores them as they are:

    * `"modes"`: each search mode the caps mark `available="yes"`, in any case (`search`,
      `tv-search`, `movie-search`, `audio-search`, `book-search`), with its `supportedParams`
      split on commas, trimmed and lowercased. A mode with no `supportedParams` lists `q`, as
      Prowlarr's `NewznabCapabilitiesProvider` reads it (Prowlarr `b0b5774`). A mode that is
      missing, or whose `available` reads anything but `yes`, lists nothing. `music-search`,
      which Prowlarr's own caps answer lists, is checked and left out.
    * `"categories"`: every `category` and `subcat` id the caps list, sorted.
    * `"limits"`: the `limits` element's `max` and `default`, each nil when absent.

  `parse/1` answers `{:error, :bad_response}`, and never raises, for a body that does not parse
  (`Cinder.Acquisition.Indexer.Newznab.XML`), a root other than `caps` (an `<error>` answer
  included), a missing `searching` or `categories` element, an element under `searching` that is
  not one of the six modes above, a mode with an attribute other than `available`,
  `supportedParams` and `searchEngine`, one of the five modes read with no `available` attribute,
  an element under `categories` other than `category`, or under a `category` other than `subcat`,
  and an id or limit that is not a non-negative integer. Of `music-search`, only the name and its
  attributes' names are checked. A body that reads wrong fails the indexer instead of leaving it
  out of searches it would take: a renamed mode or `supportedParams` would otherwise read as a
  mode the indexer lacks, or as one that takes only `q`.

  ## Categories

  `categories/2` follows Prowlarr's `IndexerCapabilitiesCategories.MapTorznabCapsToTrackers`
  (Prowlarr `b0b5774`), which picks a request's `cat`: the ids the caps list that a scope takes
  in, each listed id in the scope and each whose parent is in the scope. A listed id's parent is
  the standard parent that Prowlarr adds to its category tree with a listed child:
  `div(id, 1000) * 1000` for an id above 1000 and below 9000, and 0 for 10 and 20, the two
  standard children of 0. An id from 9000 up, or under 1000 other than 10 and 20, adds no parent:
  Prowlarr's standard parents are 0 and 1000 to 8000. So a 2000 scope reaches an indexer that
  lists only 2040, a 5070 scope does not reach one that lists only 5000, and a 9000 scope does not
  reach one that lists only 9500. A 2000 scope sends 2040 to an indexer that lists only 2040, and
  `2000,2040` to one that lists both. `covers?/2` is whether that list holds any id. Prowlarr also
  maps a listed category to a standard one by its name; this matches ids only.
  """

  alias Cinder.Acquisition.Indexer.Newznab.XML

  @type t :: %{String.t() => term()}

  @modes ~w(search tv-search movie-search audio-search book-search)
  @known_modes @modes ++ ~w(music-search)
  @mode_attributes ~w(available supportedParams searchEngine)

  @doc "Parses a `t=caps` answer body; see the moduledoc."
  @spec parse(term()) :: {:ok, t()} | {:error, :bad_response}
  def parse(body) do
    with {:ok, {"caps", _attributes, _children} = caps} <- XML.parse(body),
         {:ok, modes} <- modes(XML.child(caps, "searching")),
         {:ok, categories} <- categories(XML.child(caps, "categories")),
         {:ok, limits} <- limits(XML.child(caps, "limits")) do
      {:ok, %{"modes" => modes, "categories" => categories, "limits" => limits}}
    else
      _refused -> {:error, :bad_response}
    end
  end

  defp modes(nil), do: :error

  defp modes(searching) do
    if Enum.all?(XML.elements(searching), &known_mode?/1),
      do: read_modes(searching),
      else: :error
  end

  defp known_mode?({name, attributes, _children}) do
    name in @known_modes and
      Enum.all?(attributes, fn {key, _value} -> key in @mode_attributes end)
  end

  defp read_modes(searching) do
    Enum.reduce_while(@modes, {:ok, %{}}, fn name, {:ok, modes} ->
      case mode(XML.child(searching, name)) do
        :error -> {:halt, :error}
        nil -> {:cont, {:ok, modes}}
        params -> {:cont, {:ok, Map.put(modes, name, params)}}
      end
    end)
  end

  defp mode(nil), do: nil

  defp mode(element) do
    available = XML.attribute(element, "available")
    params = XML.attribute(element, "supportedParams")

    cond do
      available == nil -> :error
      String.downcase(available) != "yes" -> nil
      params == nil -> ["q"]
      true -> parse_params(params)
    end
  end

  defp parse_params(text) do
    text
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp categories(nil), do: :error

  defp categories(element) do
    element
    |> XML.elements()
    |> collect(fn
      {"category", _attributes, _children} = category -> category_ids(category)
      _other -> :error
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> List.flatten() |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp category_ids(category) do
    subcats =
      category
      |> XML.elements()
      |> collect(fn
        {"subcat", _attributes, _children} = subcat -> id(subcat)
        _other -> :error
      end)

    with {:ok, id} <- id(category), {:ok, subcat_ids} <- subcats, do: {:ok, [id | subcat_ids]}
  end

  defp id(element), do: integer(XML.attribute(element, "id"))

  defp limits(nil), do: {:ok, %{"max" => nil, "default" => nil}}

  defp limits(element) do
    with {:ok, max} <- optional_integer(XML.attribute(element, "max")),
         {:ok, default} <- optional_integer(XML.attribute(element, "default")),
         do: {:ok, %{"max" => max, "default" => default}}
  end

  defp optional_integer(nil), do: {:ok, nil}
  defp optional_integer(text), do: integer(text)

  defp integer(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp integer(_text), do: :error

  # `{:ok, results}` when `fun` answers `{:ok, result}` for every item, else `:error`.
  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, results} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      :error -> :error
    end
  end

  @doc "Whether the caps list `param` (lowercase) for the search mode `mode`."
  @spec param?(t(), String.t(), String.t()) :: boolean()
  def param?(%{"modes" => modes}, mode, param), do: param in Map.get(modes, mode, [])

  @doc """
  The category ids the caps list that the scope `scope` takes in, in the caps' order: each one in
  `scope`, and each whose parent is in `scope` (see the moduledoc).
  """
  @spec categories(t(), [integer()]) :: [integer()]
  def categories(%{"categories" => listed}, scope),
    do: Enum.filter(listed, fn id -> id in scope or Enum.any?(parent(id), &(&1 in scope)) end)

  @doc "Whether the caps list any category id the scope `scope` takes in (`categories/2`)."
  @spec covers?(t(), [integer()]) :: boolean()
  def covers?(caps, scope), do: categories(caps, scope) != []

  defp parent(id) when id in [10, 20], do: [0]
  defp parent(id) when id > 1000 and id < 9000, do: [div(id, 1000) * 1000]
  defp parent(_id), do: []
end
