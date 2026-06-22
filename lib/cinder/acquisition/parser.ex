defmodule Cinder.Acquisition.Parser do
  @moduledoc """
  Extracts release attributes (`resolution`, `codec`, `group`, `language`, and the
  TV `season`/`episodes`) from a release name. Pure and best-effort: an unrecognized
  field is `nil`.

  TV fields (M5b): `season` is a `pos_integer | nil`; `episodes` is a `[pos_integer]`
  for a single ep / range / multi-ep, `nil` for a whole-season pack, and `nil` when
  the name has no episode token. A movie name parses to `season: nil, episodes: nil`.
  Seasons are bounded to 1..99 — `S00` (specials), year-as-season (`S2009E12`), daily
  dates (`2024.01.15`) and absolute/anime numbering park as `nil/nil` (M6 scope). A
  name naming more than one season (`S01S02`, `S01-S03`) is rejected to `nil/nil`
  rather than mis-read as a single season — that keeps M5c's pack import honest.

  `size` is intentionally not parsed here — it comes from the indexer's reported
  byte count (see `Cinder.Acquisition`).
  """

  @resolutions ["2160p", "1080p", "720p", "480p"]

  @codecs [
    {~r/x265/i, "x265"},
    {~r/h\.?265/i, "h265"},
    {~r/hevc/i, "h265"},
    {~r/x264/i, "x264"},
    {~r/h\.?264/i, "h264"},
    {~r/avc/i, "h264"},
    {~r/av1/i, "av1"},
    {~r/xvid/i, "xvid"}
  ]

  @languages [
    {~r/\bmulti\b/i, "MULTI"},
    {~r/\bfrench\b/i, "FRENCH"},
    {~r/\bgerman\b/i, "GERMAN"},
    {~r/\bspanish\b/i, "SPANISH"},
    {~r/\bitalian\b/i, "ITALIAN"}
  ]

  # Adjacent (S01S02) or dash-joined (S01-S03) season tokens — the forms a boundary
  # scan can't see (no separator before the second S). Combined with distinct_seasons/1
  # below in multi_season?/1; either firing rejects the name to nil/nil rather than
  # mis-reading it as season 1. (M5c would otherwise grab it and strand other seasons.)
  @multi_season ~r/s\d{1,2}\s*-\s*s\d{1,2}|s\d{1,2}s\d{1,2}/i
  # A real season token at a word boundary: S + 1-2 digits followed by a separator,
  # an episode marker, or end — so a group/title fragment like "-S1CK" or "S5RT" (digit
  # glued to a letter) is not counted as a season. Scanned to count distinct seasons.
  @season_token ~r/(?:^|[^a-z0-9])s(\d{1,2})(?=[\s._-]|e\d|$)/i
  # Season + an episode tail (an optional ./space/_ separator allowed): SxxEyy, Sxx.Eyy,
  # SxxEyyEzz, SxxEyy-Ezz, SxxEyy-zz (tail parsed below).
  @season_episode ~r/(?:^|[^a-z0-9])s(\d{1,2})[._ ]?((?:e\d{1,3})(?:-?e?\d{1,3})*)/i
  # The 1x02 form (single episode only).
  @alt_episode ~r/(?:^|[^a-z0-9])(\d{1,2})x(\d{1,2})(?!\d)/i
  # A bare season pack: S01 / S01.COMPLETE (no episode token following).
  @bare_season ~r/(?:^|[^a-z0-9])s(\d{1,2})(?![0-9e])/i
  # The "Season N" / "Season.05" word form (pack).
  @season_word ~r/season[ ._]?(\d{1,2})(?!\d)/i
  # One episode-tail token: an optional leading "-" (range from the previous), an
  # optional "E", then the number.
  @tail_token ~r/(-)?e?(\d{1,3})/i

  @doc """
  Parses `name` into `%{resolution, codec, group, language, season, episodes}`. Each
  value is `nil` when no known token matches. A non-binary `name` (e.g. an indexer
  result with a missing title) yields all-`nil` rather than raising, keeping the
  parser total.
  """
  def parse(name) when is_binary(name) do
    {season, episodes} = season_episodes(name)

    %{
      resolution: resolution(name),
      codec: first_match(name, @codecs),
      group: group(name),
      language: first_match(name, @languages),
      season: season,
      episodes: episodes
    }
  end

  def parse(_name),
    do: %{resolution: nil, codec: nil, group: nil, language: nil, season: nil, episodes: nil}

  defp resolution(name) do
    down = String.downcase(name)
    Enum.find(@resolutions, &String.contains?(down, &1))
  end

  defp first_match(name, table) do
    Enum.find_value(table, fn {pattern, value} -> if Regex.match?(pattern, name), do: value end)
  end

  # The trailing "-TOKEN", but only when TOKEN is a single alphanumeric run (no
  # dots/spaces), after stripping a container extension. Otherwise nil — so a
  # hyphenated title ("Spider-Man") or a source token ("WEB-DL.H264") is never read
  # as a group. See the spec for the two accepted, bounded edge cases.
  defp group(name) do
    stripped = Regex.replace(~r/\.(mkv|mp4|avi|m4v|ts)$/i, name, "")

    case Regex.run(~r/-([A-Za-z0-9]+)$/, stripped) do
      [_, group] -> group
      nil -> nil
    end
  end

  # Resolves {season, episodes}, most-specific first. Early-return ordering keeps a
  # single (SxxEyy) from being read as a bare-season pack.
  defp season_episodes(name) do
    cond do
      multi_season?(name) -> {nil, nil}
      match = Regex.run(@season_episode, name) -> from_tail(match)
      match = Regex.run(@alt_episode, name) -> single(match)
      match = Regex.run(@bare_season, name) -> bare(match)
      match = Regex.run(@season_word, name) -> bare(match)
      true -> {nil, nil}
    end
  end

  # A name carries more than one season ⇒ a multi-season/whole-series pack. Reject it
  # (nil/nil) so it's never mis-read as one season. Catches adjacent/dash forms via
  # @multi_season and any separator (S01.S02, S01 S02, S01E01.S02E02) via the count.
  defp multi_season?(name) do
    Regex.match?(@multi_season, name) or distinct_seasons(name) > 1
  end

  defp distinct_seasons(name) do
    @season_token
    |> Regex.scan(name)
    |> Enum.map(fn [_, season] -> String.to_integer(season) end)
    |> Enum.uniq()
    |> length()
  end

  defp from_tail([_, season, tail]),
    do: validate(String.to_integer(season), parse_tail(tail))

  defp single([_, season, episode]) do
    ep = String.to_integer(episode)
    if ep?(ep), do: validate(String.to_integer(season), [ep]), else: {nil, nil}
  end

  defp bare([_, season]), do: validate(String.to_integer(season), nil)

  # Walk the episode tail left-to-right: a plain "E03" token is a discrete episode; a
  # "-E03" token expands the range from the previous episode. At the first token that
  # isn't a valid in-band ascending continuation — a descending range, or a hyphen-glued
  # resolution like "S01E02-720p" (→ "-720") — stop and keep the episodes parsed so far,
  # so the leading valid episode survives instead of the whole release being dropped. An
  # empty result (first token already junk, e.g. "S01E720") parks the name via validate/2.
  defp parse_tail(tail) do
    @tail_token
    |> Regex.scan(tail)
    |> Enum.reduce_while({[], nil}, fn
      [_, "-", num], {acc, last} ->
        n = String.to_integer(num)

        if is_integer(last) and n > last and ep?(n),
          do: {:cont, {acc ++ Enum.to_list((last + 1)..n//1), n}},
          else: {:halt, {acc, last}}

      [_, _, num], {acc, last} ->
        n = String.to_integer(num)
        if ep?(n), do: {:cont, {acc ++ [n], max(n, last || n)}}, else: {:halt, {acc, last}}
    end)
    |> then(fn {episodes, _last} -> Enum.uniq(episodes) end)
  end

  # A sane SxxEyy episode number: 1..99. Bounds the tail so an attached resolution
  # ("S01E01-1080p" → "108") can't be expanded into a giant episode range.
  defp ep?(n), do: n in 1..99

  defp validate(season, _episodes) when season < 1 or season > 99, do: {nil, nil}
  defp validate(_season, []), do: {nil, nil}
  defp validate(season, episodes), do: {season, episodes}
end
