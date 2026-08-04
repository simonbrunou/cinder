defmodule Cinder.Acquisition.AnimeParser do
  @moduledoc """
  Parses anime release coordinates without changing the standard TV parser.

  Bare absolute coordinates are accepted only after a known Unicode title.
  Typed specials remain unresolved until Catalog supplies an explicit mapping.
  """

  @max_range 100

  def parse(title, %{kind: :movie}) when is_binary(title) do
    %{coordinates: [], role: :story, group: prefix_group(title)}
  end

  def parse(title, %{kind: :series} = context) when is_binary(title) do
    cond do
      extra?(title) ->
        result([], :extra, title)

      coordinates = standard_coordinates(title) ->
        result(coordinates, :story, title)

      coordinates = typed_special(title) ->
        result(coordinates, :unknown, title)

      scene_title = scene_title_remainder(title, Map.get(context, :scene_titles, [])) ->
        scene_result(scene_title, context, title)

      remainder = title_remainder(title, context.titles) ->
        absolute_result(remainder, context, title)

      true ->
        result([], :unknown, title)
    end
  end

  def parse(_title, _context), do: %{coordinates: [], role: :unknown, group: nil}

  defp result(coordinates, role, title) do
    %{coordinates: coordinates, role: role, group: prefix_group(title)}
  end

  defp absolute_result(remainder, context, title) do
    case absolute_coordinates(remainder, context) do
      nil -> result([], :unknown, title)
      coordinates -> result(coordinates, :story, title)
    end
  end

  # A bare coordinate remains series-absolute unless Catalog has correlated the matched title to
  # one exact subgroup in the selected scene-numbering order. The explicit scene scope keeps arc
  # releases such as "Koyomimonogatari - 05" safe while preserving the generic absolute rule.
  defp scene_result({remainder, scope}, context, title) do
    case absolute_coordinates(remainder, context) do
      nil ->
        result([], :unknown, title)

      [%{values: values}] ->
        scene_values = Enum.map(values, &standard_value(Integer.to_string(scope.season), &1))

        coordinate =
          coordinate("scene", scene_values)
          |> Map.merge(%{source: scope.source, namespace: scope.namespace})

        result([coordinate], :story, title)
    end
  end

  # Range separators accept the ASCII hyphen plus the wave-dash variants (~ 〜 ～) used by
  # CJK-origin uploaders, e.g. a Nyaa batch range written 总第67~77 (A5 dogfood F3, issue #106).
  defp standard_coordinates(title) do
    case Regex.run(
           ~r/\bS(\d{1,3})E(\d{1,4})(?:\s*[-~〜～]\s*(?:S(\d{1,3})E(\d{1,4})|E?(\d{1,4})\b))?/iu,
           title,
           capture: :all_but_first
         ) do
      [season, episode, "", "", tail_episode] ->
        same_season_coordinates(season, episode, tail_episode)

      [season, episode, end_season, end_episode] ->
        values = [standard_value(season, episode), standard_value(end_season, end_episode)]
        [coordinate("standard", values)]

      [season, episode] ->
        [coordinate("standard", [standard_value(season, episode)])]

      _ ->
        nil
    end
  end

  # Same-season shorthand tail ("-E12" or "-12"): expand to the full episode range when it's a
  # sane ascending span, otherwise fall back to just the leading episode — a descending or
  # oversized range is unparseable, not garbage to guess at (mirrors the standard parser's
  # halt-and-keep-what-parsed-so-far behaviour for a bad tail token).
  defp same_season_coordinates(season, start_episode, end_episode) do
    start_number = String.to_integer(start_episode)
    end_number = String.to_integer(end_episode)
    width = end_number - start_number + 1

    if end_number > start_number and width <= @max_range do
      values = Enum.map(start_number..end_number, &standard_value(season, Integer.to_string(&1)))
      [coordinate("standard", values)]
    else
      [coordinate("standard", [standard_value(season, start_episode)])]
    end
  end

  defp standard_value(season, episode) do
    "S#{pad_number(season, 2)}E#{pad_number(episode, 2)}"
  end

  defp pad_number(value, width) do
    value
    |> String.to_integer()
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end

  defp typed_special(title) do
    cond do
      captures = Regex.run(~r/\b(OVA|OAD|ONA)\s*[-._ ]?\s*(\d+)\b/iu, title) ->
        [_match, type, number] = captures
        [coordinate("typed_special", ["#{String.upcase(type)}:#{String.to_integer(number)}"])]

      Regex.match?(~r/\bRECAP\b/iu, title) ->
        [coordinate("typed_special", ["RECAP"])]

      captures = Regex.run(~r/\bEPISODE\s*0\b/iu, title) ->
        [_match] = captures
        [coordinate("typed_special", ["EPISODE:0"])]

      true ->
        nil
    end
  end

  # Absolute range separators also accept en/em dashes used in human-written arc batch titles,
  # plus the CJK wave-dash variants (~ 〜 ～), e.g. 总第67~77.
  defp absolute_coordinates(remainder, context) do
    case Regex.run(
           ~r/^\s*(?:[-–—._]\s*)?(?:总?第\s*)?(\d{1,6})(?:\s*[-–—~〜～]\s*(\d{1,6}))?(?:v\d+)?[话集]?(?:\b|$)/iu,
           remainder,
           capture: :all_but_first
         ) do
      [value] -> absolute_scalar(value, context)
      [first, last] -> absolute_range(first, last, context)
      _ -> nil
    end
  end

  defp absolute_scalar(value, context) do
    number = String.to_integer(value)

    if year?(number, value, context) do
      nil
    else
      [coordinate("absolute", [Integer.to_string(number)])]
    end
  end

  defp absolute_range(first, last, context) do
    first_number = String.to_integer(first)
    last_number = String.to_integer(last)
    width = last_number - first_number + 1

    if year?(first_number, first, context) or year?(last_number, last, context) or width < 1 or
         width > @max_range do
      nil
    else
      values = Enum.map(first_number..last_number, &Integer.to_string/1)
      [coordinate("absolute", values)]
    end
  end

  defp year?(number, value, context) do
    String.length(value) == 4 and
      (number in 1900..(Date.utc_today().year + 1) or number == context.year)
  end

  defp coordinate(scheme, values), do: %{scheme: scheme, values: values}

  defp extra?(title) do
    Regex.match?(
      ~r/(?:^|[\s._\-\[\]()])(?:NCOP|NCED|TRAILER)(?:\s*\d+)?(?:$|[\s._\-\[\]()])/iu,
      title
    )
  end

  defp title_remainder(title, titles) do
    normalized_title = title |> strip_group() |> String.normalize(:nfkc)

    titles
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.normalize(&1, :nfkc))
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find_value(&matching_remainder(normalized_title, &1))
  end

  defp scene_title_remainder(title, scene_titles) when is_list(scene_titles) do
    normalized_title = title |> strip_group() |> String.normalize(:nfkc)

    scene_titles
    |> Enum.map(&scene_title/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {known_title, _scope} -> String.length(known_title) end, :desc)
    |> Enum.find_value(fn {known_title, scope} ->
      case matching_remainder(normalized_title, known_title) do
        nil -> nil
        remainder -> {remainder, scope}
      end
    end)
  end

  defp scene_title_remainder(_title, _scene_titles), do: nil

  defp scene_title(scene_title) when is_map(scene_title) do
    title = scene_title_field(scene_title, :title)
    season = scene_title_field(scene_title, :season)
    source = scene_title_field(scene_title, :source)
    namespace = scene_title_field(scene_title, :namespace)

    if valid_title_and_season?(title, season) and present_string?(source) and
         present_string?(namespace) do
      scope = %{season: season, source: source, namespace: namespace}
      {String.normalize(title, :nfkc), scope}
    end
  end

  defp scene_title(_scene_title), do: nil

  defp scene_title_field(scene_title, key),
    do: Map.get(scene_title, key) || Map.get(scene_title, Atom.to_string(key))

  defp valid_title_and_season?(title, season),
    do: is_binary(title) and is_integer(season) and season >= 0

  defp present_string?(value), do: is_binary(value) and value != ""

  defp matching_remainder(title, known_title) do
    if String.starts_with?(String.downcase(title), String.downcase(known_title)) do
      {_prefix, remainder} = String.split_at(title, String.length(known_title))
      if legal_title_boundary?(remainder), do: remainder
    end
  end

  defp legal_title_boundary?(""), do: true
  defp legal_title_boundary?(remainder), do: Regex.match?(~r/^[\s._\-–—(]/u, remainder)

  defp prefix_group(title) do
    case Regex.run(~r/^\s*\[([^\]\r\n]+)\]\s*/u, title, capture: :all_but_first) do
      [group] -> String.trim(group)
      _ -> nil
    end
  end

  defp strip_group(title), do: Regex.replace(~r/^\s*\[[^\]\r\n]+\]\s*/u, title, "")
end
