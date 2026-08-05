defmodule Cinder.Acquisition.AnimeParser do
  @moduledoc """
  Parses anime release coordinates without changing the standard TV parser.

  Bare absolute coordinates are accepted only after a known Unicode title.
  Typed specials remain unresolved until Catalog supplies an explicit mapping.
  """

  alias Cinder.Catalog.TitleAlias

  @max_range 100

  def parse(title, %{kind: :movie}) when is_binary(title) do
    %{coordinates: [], role: :story, group: prefix_group(title)}
  end

  def parse(title, %{kind: :series} = context) when is_binary(title) do
    if extra?(title) do
      result([], :extra, title)
    else
      parse_series_result(title, context, standard_coordinates_for_title(title, context))
    end
  end

  def parse(_title, _context), do: %{coordinates: [], role: :unknown, group: nil}

  defp parse_series_result(title, context, standard_coordinates) do
    typed_coordinates = typed_special(title)

    cond do
      standard_coordinates == :blocked ->
        invalid_coordinate_result(title)

      standard_coordinates && blocked_title_outranks_positive?(title, context) ->
        invalid_coordinate_result(title)

      standard_coordinates ->
        result(standard_coordinates, :story, title)

      blocked_title_match?(title, context) ->
        invalid_coordinate_result(title)

      typed_coordinates ->
        typed_special_result(title, context, typed_coordinates)

      true ->
        title
        |> relative_result(context)
        |> mark_invalid_coordinate_syntax(title, context)
    end
  end

  defp invalid_coordinate_result(title) do
    result([], :unknown, title)
    |> Map.put(:blocked_coordinate, true)
    |> Map.put(:invalid_coordinate, true)
  end

  defp malformed_coordinate_result(title) do
    result([], :unknown, title)
    |> Map.put(:invalid_coordinate, true)
  end

  defp blocked_title_match?(title, context) do
    blocked_match = title_remainder(title, Map.get(context, :blocked_titles, []))
    positive_match = title_remainder(title, positive_titles(context))

    case {blocked_match, positive_match} do
      {nil, _positive} ->
        false

      {{_, blocked_title}, nil} ->
        String.length(blocked_title) > 0

      {{_, blocked_title}, {_, positive_title}} ->
        String.length(blocked_title) >= String.length(positive_title)
    end
  end

  defp blocked_title_outranks_positive?(title, context) do
    blocked_match = title_remainder(title, Map.get(context, :blocked_titles, []))
    positive_match = title_remainder(title, positive_titles(context))

    case {blocked_match, positive_match} do
      {nil, _positive} ->
        false

      {{_, blocked_title}, nil} ->
        String.length(blocked_title) > 0

      {{_, blocked_title}, {_, positive_title}} ->
        String.length(blocked_title) > String.length(positive_title)
    end
  end

  defp positive_titles(context) do
    scene_titles =
      context
      |> Map.get(:scene_titles, [])
      |> Enum.flat_map(fn entry ->
        case scene_title(entry) do
          {title, _scope} -> [title]
          nil -> []
        end
      end)

    Map.get(context, :titles, []) ++ scene_titles
  end

  defp mark_invalid_coordinate_syntax(%{coordinates: []} = parsed, title, context) do
    cleaned = coordinate_fallback_tail(title, context)

    if coordinate_like_syntax?(cleaned) or absolute_coordinate_tokens(cleaned) != [],
      do: Map.put(parsed, :invalid_coordinate, true),
      else: parsed
  end

  defp mark_invalid_coordinate_syntax(parsed, _title, _context), do: parsed

  defp coordinate_fallback_tail(title, context) do
    tail =
      case title_remainder(title, positive_titles(context)) do
        {remainder, _matched_title} -> remainder
        nil -> title
      end

    tail
    |> strip_cinder_suffix()
    |> strip_terminal_extension()
    |> remove_checksum_metadata()
    |> remove_numeric_metadata(context)
  end

  defp strip_terminal_extension(title) do
    Regex.replace(~r/\.[a-z0-9]{1,10}$/iu, title, "")
  end

  defp coordinate_like_syntax?(title) do
    Regex.match?(~r/(?:S\d+E\d+|(?:^|[^\p{L}\p{N}])E\d+)/iu, title) or
      Regex.match?(
        ~r/(?:^|[^\p{L}\p{N}])\d{1,4}\s*[\p{P}\p{S}]\s*(?:S\d+E\d+|E?\d{1,4})(?:\s*[\p{P}\p{S}]\s*(?:E?\d{1,4}))?/iu,
        title
      )
  end

  defp typed_special_result(title, context, coordinates) do
    if malformed_coordinate_before_typed_special?(title, context),
      do: malformed_coordinate_result(title),
      else: result(coordinates, :unknown, title)
  end

  defp malformed_coordinate_before_typed_special?(title, context) do
    case typed_special_prefix(title) do
      prefix when is_binary(prefix) ->
        case title_remainder(prefix, positive_titles(context)) do
          {remainder, _matched_title} ->
            malformed_coordinate_tail_fragment?(remainder, context)

          nil ->
            malformed_unknown_title_prefix?(prefix, context)
        end

      nil ->
        false
    end
  end

  defp malformed_unknown_title_prefix?(prefix, context) do
    tail_without_checksums = remove_checksum_metadata(prefix)
    cleaned = remove_numeric_metadata(tail_without_checksums, context)

    attached_standard_coordinate?(tail_without_checksums) or over_width_coordinate?(cleaned) or
      later_standard_coordinate?(cleaned) or length(absolute_coordinate_tokens(cleaned)) > 1
  end

  defp typed_special_prefix(title) do
    regex = ~r/\b(?:OVA|OAD|ONA)\s*[-._ ]?\s*\d+\b|\bRECAP\b|\bEPISODE\s*0\b/iu

    case Regex.run(regex, title, return: :index) do
      [{start, _length} | _captures] -> binary_part(title, 0, start)
      nil -> nil
    end
  end

  # A scoped alias is evidence, not unconditional precedence. Compare it with the same longest
  # canonical/alias match used by ordinary absolute parsing so a prefix such as "Foo" cannot
  # consume the numeric continuation in the longer canonical title "Foo 2" as a scene range.
  defp relative_result(title, context) do
    blocked_titles = Map.get(context, :blocked_titles, [])

    scene_match =
      scene_title_remainder(
        title,
        reject_blocked_scene_titles(Map.get(context, :scene_titles, []), blocked_titles)
      )

    generic_match = title_remainder(title, reject_blocked_titles(context.titles, blocked_titles))

    cond do
      prefer_scene_match?(scene_match, generic_match) ->
        scene_result(scene_match, context, title)

      generic_match ->
        {remainder, _known_title} = generic_match
        absolute_result(remainder, context, title)

      true ->
        result([], :unknown, title)
    end
  end

  defp reject_blocked_titles(titles, blocked_titles) do
    blocked = MapSet.new(Enum.map(blocked_titles, &TitleAlias.normalize/1))
    Enum.reject(titles, &MapSet.member?(blocked, TitleAlias.normalize(&1)))
  end

  defp reject_blocked_scene_titles(scene_titles, blocked_titles) do
    blocked = MapSet.new(Enum.map(blocked_titles, &TitleAlias.normalize/1))

    Enum.reject(scene_titles, fn scene_title ->
      scene_title = scene_title_field(scene_title, :title)
      is_binary(scene_title) and MapSet.member?(blocked, TitleAlias.normalize(scene_title))
    end)
  end

  defp prefer_scene_match?(
         {_scene_remainder, _scope, scene_title},
         {_generic_remainder, generic_title}
       ),
       do: String.length(scene_title) >= String.length(generic_title)

  defp prefer_scene_match?({_remainder, _scope, _scene_title}, nil), do: true
  defp prefer_scene_match?(_scene_match, _generic_match), do: false

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
  defp scene_result({remainder, scope, _known_title}, context, title) do
    case absolute_coordinates(remainder, context) do
      nil ->
        result([], :unknown, title)

      [%{values: values}] ->
        scene_values = Enum.map(values, &standard_value(Integer.to_string(scope.season), &1))

        coordinate =
          coordinate("scene", scene_values)
          |> Map.merge(%{
            source: scope.source,
            namespace: scope.namespace,
            scope_title: scope.normalized_title
          })

        result([coordinate], :story, title)
    end
  end

  # Standard coordinates are recognized only in the remainder of the longest known title. Searching
  # the whole release lets a malformed relative chain such as "Arc 01-02-S11E03" escape its
  # scoped title and get reinterpreted as an unrelated unscoped scene coordinate.
  defp standard_coordinates_for_title(title, context) do
    generic_match = title_remainder(title, Map.get(context, :titles, []))
    scene_match = scene_title_remainder(title, Map.get(context, :scene_titles, []))

    {remainder, matched_title} =
      cond do
        prefer_scene_match?(scene_match, generic_match) ->
          {elem(scene_match, 0), elem(scene_match, 2)}

        generic_match ->
          generic_match

        true ->
          {nil, nil}
      end

    direct_only? = not is_nil(matched_title) and blocked_title?(matched_title, context)

    coordinates = standard_coordinates_for_match(title, remainder, direct_only?, context)

    if direct_only? and is_nil(coordinates) and standard_coordinates(remainder, context, false),
      do: :blocked,
      else: coordinates
  end

  defp standard_coordinates_for_match(title, remainder, direct_only?, context)
       when is_binary(remainder) do
    case standard_coordinates(remainder, context, direct_only?) do
      nil when not direct_only? -> maybe_unscoped_standard_coordinates(title, context)
      coordinates -> coordinates
    end
  end

  defp standard_coordinates_for_match(title, _remainder, _direct_only?, context) do
    maybe_unscoped_standard_coordinates(title, context)
  end

  defp maybe_unscoped_standard_coordinates(title, context) do
    if Map.get(context, :allow_unscoped_standard, false),
      do: unscoped_standard_coordinates(title, context)
  end

  defp unscoped_standard_coordinates(title, context) do
    case Regex.run(~r/(?<![\p{L}\p{N}])S\d{1,3}E\d{1,4}/iu, title, return: :index) do
      [{start, _length}] ->
        prefix = binary_part(title, 0, start)

        unless unsafe_unscoped_prefix?(prefix, context) do
          standard_coordinates(
            binary_part(title, start, byte_size(title) - start),
            context,
            false
          )
        end

      _no_coordinate ->
        nil
    end
  end

  defp unsafe_unscoped_prefix?(prefix, context) do
    malformed_unknown_title_prefix?(prefix, context)
  end

  defp blocked_title?(title, context) do
    normalized = TitleAlias.normalize(title)

    context
    |> Map.get(:blocked_titles, [])
    |> Enum.any?(&(TitleAlias.normalize(&1) == normalized))
  end

  # Range separators accept the ASCII hyphen plus the wave-dash variants (~ 〜 ～) used by
  # CJK-origin uploaders, e.g. a Nyaa batch range written 总第67~77 (A5 dogfood F3, issue #106).
  defp standard_coordinates(remainder, context, direct_only?) do
    remainder = strip_context_year_prefix(remainder, context)

    case Regex.run(standard_coordinate_pattern(direct_only?), remainder) do
      nil ->
        nil

      [matched | captures] ->
        unless malformed_coordinate_tail?(remainder, matched, context),
          do: standard_coordinate_captures(captures)
    end
  end

  defp strip_context_year_prefix(remainder, %{year: year}) when is_integer(year) do
    Regex.replace(~r/^\D*?#{year}\D*?(?=S\d{1,3}E\d{1,4})/iu, remainder, "")
  end

  defp strip_context_year_prefix(remainder, _context), do: remainder

  defp standard_coordinate_pattern(true),
    do:
      ~r/^\s*(?:[-–—._]\s*)?S(\d{1,3})E(\d{1,4})(?:\s*[-~〜～]\s*(?:S(\d{1,3})E(\d{1,4})|E?(\d{1,4})\b))?/iu

  defp standard_coordinate_pattern(false),
    do:
      ~r/^\D*?(?<![\p{L}\p{N}])S(\d{1,3})E(\d{1,4})(?:\s*[-~〜～]\s*(?:S(\d{1,3})E(\d{1,4})|E?(\d{1,4})\b))?/iu

  defp standard_coordinate_captures([season, episode, "", "", tail_episode]),
    do: same_season_coordinates(season, episode, tail_episode)

  defp standard_coordinate_captures([season, episode, end_season, end_episode]) do
    start_season = String.to_integer(season)
    finish_season = String.to_integer(end_season)

    start_episode = String.to_integer(episode)
    finish_episode = String.to_integer(end_episode)

    cond do
      finish_season == start_season ->
        same_season_coordinates(season, episode, end_episode)

      finish_season == start_season + 1 and start_episode <= @max_range and
          finish_episode <= @max_range ->
        values = [standard_value(season, episode), standard_value(end_season, end_episode)]
        [coordinate("standard", values)]

      true ->
        nil
    end
  end

  defp standard_coordinate_captures([season, episode]),
    do: [coordinate("standard", [standard_value(season, episode)])]

  # Same-season shorthand tail ("-E12" or "-12"): expand to the full episode range only when it
  # is a sane ascending span. Once explicit range syntax is recognized, a descending or oversized
  # tail must fail closed instead of silently reserving only the leading episode.
  defp same_season_coordinates(season, start_episode, end_episode) do
    start_number = String.to_integer(start_episode)
    end_number = String.to_integer(end_episode)
    width = end_number - start_number + 1

    if end_number > start_number and width <= @max_range do
      values = Enum.map(start_number..end_number, &standard_value(season, Integer.to_string(&1)))
      [coordinate("standard", values)]
    else
      nil
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
           remainder
         ) do
      [matched, value] ->
        unless malformed_coordinate_tail?(remainder, matched, context),
          do: absolute_scalar(value, context)

      [matched, first, last] ->
        unless malformed_coordinate_tail?(remainder, matched, context),
          do: absolute_range(first, last, context)

      _ ->
        nil
    end
  end

  # Every caller uses an anchored coordinate regex, so the returned match is always the exact
  # prefix whose tail must be validated. Using a second binary search here can select an identical
  # earlier token and validate the wrong suffix.
  defp malformed_coordinate_tail?(text, matched, context) do
    tail_start = byte_size(matched)

    tail =
      text
      |> binary_part(tail_start, byte_size(text) - tail_start)
      |> strip_cinder_suffix()

    malformed_coordinate_tail_fragment?(tail, context)
  end

  defp strip_cinder_suffix(tail) do
    Regex.replace(
      ~r/\.cinder-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:\.[a-z0-9]{1,10})?$/iu,
      tail,
      ""
    )
  end

  # Examine the remaining suffix as tokens. Known release metadata is removed first; any remaining
  # standard coordinate or standalone number is a second coordinate and invalidates the prefix.
  defp malformed_coordinate_tail_fragment?(tail, context) do
    tail_without_checksums = remove_checksum_metadata(tail)
    cleaned = remove_numeric_metadata(tail_without_checksums, context)

    attached_standard_coordinate?(tail_without_checksums) or over_width_coordinate?(cleaned) or
      later_standard_coordinate?(cleaned) or later_absolute_coordinate?(cleaned)
  end

  # A later coordinate remains coordinate evidence even when it is glued to a metadata token.
  # Isolated eight-digit hexadecimal checksums are removed before this detector runs.
  defp attached_standard_coordinate?(tail) do
    Regex.match?(~r/[\p{L}\p{N}]S\d{1,3}E\d{1,4}/iu, tail) or
      Regex.match?(~r/[\p{L}\p{N}._-]+?E\d{1,4}/iu, tail)
  end

  defp remove_checksum_metadata(tail) do
    Regex.replace(
      ~r/(?<![\p{L}\p{N}])(?:[0-9a-f]{8}|[0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{64})(?![\p{L}\p{N}])/iu,
      tail,
      " "
    )
  end

  defp remove_numeric_metadata(tail, context) do
    patterns = [
      ~r/(?<![\d.-])(?:19|20)\d{2}[.-]\d{1,2}[.-]\d{1,2}(?![\d.-])/u,
      ~r/(?<![\d.-])(?:19|20)\d{2}[.-]\d{1,2}(?![\d.-])/u,
      ~r/(?<![\p{L}\p{N}])batch[\s._-]*\d{1,3}(?!\d)/iu,
      ~r/(?<![\p{L}\p{N}])\d{1,2}\s*(?:audio\s*)?tracks?\b/iu,
      ~r/(?<![\p{L}\p{N}])\d{1,3}\s*(?:subs?|subtitles?)\b/iu,
      ~r/(?<![\p{L}\p{N}])(?:vol(?:ume)?|disc|disk|part)[\s._-]*\d{1,3}(?!\d)/iu,
      ~r/\b(?:x26[45]|h[\s._-]?26[45])\b/iu,
      ~r/\b\d{1,2}\s*[- ]?\s*bit\b/iu,
      ~r/\b\d{1,3}(?:\.\d+)?\s*fps\b/iu,
      ~r/\b\d{1,2}(?:\.\d+)?\s*ch\b/iu,
      ~r/\b(?:DDP?|AAC|E?AC-?3|DTS(?:-?HD)?|TRUEHD|ATMOS)\s*\d(?:\.\d+){1,2}\b/iu,
      ~r/(?<![\d.])[1-9](?:\.\d+){1,2}(?![\d.])/u,
      ~r/\b\d{3,4}[pi]\b/iu
    ]

    cleaned = Enum.reduce(patterns, tail, &Regex.replace(&1, &2, " "))
    remove_year_metadata(cleaned, context)
  end

  defp remove_year_metadata(tail, context) do
    Regex.replace(~r/(?<!\d)\d{4}(?!\d)/u, tail, fn value ->
      number = String.to_integer(value)
      if year?(number, value, context), do: " ", else: value
    end)
  end

  defp over_width_coordinate?(tail) do
    Regex.match?(~r/(?:^|[^\p{L}\p{N}])(?:S\d{4,}E\d+|S\d+E\d{5,}|E\d{5,})/iu, tail)
  end

  defp later_standard_coordinate?(tail) do
    Regex.match?(~r/(?:^|[^\p{L}\p{N}])(?:S\d{1,3}E|E)\d{1,4}/iu, tail)
  end

  defp later_absolute_coordinate?(tail), do: absolute_coordinate_tokens(tail) != []

  defp absolute_coordinate_tokens(tail) do
    Regex.scan(
      ~r/(?:^|[^\p{L}\p{N}])(?:总?第\s*)?\d{1,6}(?:v\d+)?[话集]?(?=$|[^\p{L}\p{N}])/iu,
      tail
    )
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
    normalized_title = title |> strip_group() |> TitleAlias.normalize()

    titles
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&TitleAlias.normalize/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find_value(fn known_title ->
      case matching_remainder(normalized_title, known_title) do
        nil -> nil
        remainder -> {remainder, known_title}
      end
    end)
  end

  defp scene_title_remainder(title, scene_titles) when is_list(scene_titles) do
    normalized_title = title |> strip_group() |> TitleAlias.normalize()

    scene_titles
    |> Enum.map(&scene_title/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {known_title, _scope} -> String.length(known_title) end, :desc)
    |> Enum.find_value(fn {known_title, scope} ->
      case matching_remainder(normalized_title, known_title) do
        nil -> nil
        remainder -> {remainder, scope, known_title}
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
      scope = %{
        season: season,
        source: source,
        namespace: namespace,
        normalized_title: TitleAlias.normalize(title)
      }

      {scope.normalized_title, scope}
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
