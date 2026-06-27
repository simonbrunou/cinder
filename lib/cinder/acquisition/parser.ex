defmodule Cinder.Acquisition.Parser do
  @moduledoc """
  Extracts release attributes (`resolution`, `source`, `codec`, `group`, `language`, and the
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

  `language` matches an audio-language tag in the name (see `@language_registry`); subtitle markers
  ("ENG.SUBS", "VOSTFR") are stripped first so they aren't read as audio. A title word that is also a
  language ("The Italian Job") can still match — that soft collision is handled downstream by the
  language filter's Original/Any fallback in `Cinder.Acquisition`.
  """

  @resolutions ["2160p", "1080p", "720p", "480p"]

  # Release source, split by ambiguity. @sources are compound tokens that are never a release-TITLE
  # word, so they match ANYWHERE in the name (most-specific-first, same first_match/2 mechanism as
  # @codecs). Collision-prone 2-letter abbreviations (ts, tc, bd, scr, dsr) are excluded — same
  # discipline as the language registry's "vf is the lone 2-letter token" note. `bdremux` is a remux
  # (`\bremux\b` alone can't match "BDRemux" — no boundary before remux).
  @sources [
    {~r/\bremux\b|\bbdremux\b/i, "remux"},
    {~r/\bblu-?ray\b|\bbrrip\b|\bbdrip\b/i, "bluray"},
    {~r/\bweb-?rip\b/i, "webrip"},
    {~r/\bweb-?dl\b/i, "webdl"},
    {~r/\bhdtv\b|\bpdtv\b/i, "hdtv"},
    {~r/\bdvd-?rip\b/i, "dvd"},
    {~r/\btelesync\b|\btelecine\b|\bscreener\b/i, "cam"}
  ]

  # @bare_sources are single words that ARE real source tags but can also be a release TITLE word
  # ("Cam" the film, "...Web", "DVD"). They're scanned only in the tag region (past the first
  # year/resolution marker) so a title word can't produce a false (non-nil) source — which would
  # defeat the scorer's nil-passes valve and wrongly reject the release. A bare token before the
  # resolution in a yearless name (e.g. "Movie.CAM.480p") falls to nil: benign, the valve keeps it.
  @bare_sources [
    {~r/\bweb\b/i, "webdl"},
    {~r/\bdvd\b/i, "dvd"},
    {~r/\bcam\b/i, "cam"}
  ]

  # Start of the tag region: the first year or resolution marker — the title precedes it.
  @tag_region_anchor ~r/\b(?:19|20)\d{2}\b|\b(?:2160|1080|720|480)p\b/i

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

  # Canonical audio-language registry — the single source of truth shared with
  # `Cinder.Acquisition.Language`. Each entry is `{iso_code, tag, name_pattern}`: the parser
  # maps a release NAME → tag, and `Language` maps a TMDB `original_language` / user pick (the
  # iso code) ↔ tag. Keeping both directions in ONE table is deliberate — the per-item language
  # filter let a foreign dub through as "original" because the parser didn't recognise a tag the
  # filter needed, and two hand-synced tables would let that drift recur.
  #
  # Tokens are adapted from Radarr's `LanguageParser` (GPL-3.0, the same licence as Cinder) and
  # vetted for false positives: full English word + native endonym + only low-collision
  # abbreviations, each `\b`-anchored (the French audio marker `vf` is the lone 2-letter token).
  # Subtitle markers ("HUN.ENG.SUBS", "LATINO.SUBS") are stripped by `strip_subtitles/1` BEFORE
  # matching, so the patterns themselves stay simple. `iso_code` matches TMDB `original_language`
  # — note "cn" = Cantonese, "zh" = Mandarin/Chinese.
  @language_registry [
    {"fr", "FRENCH", ~r/\bfrench\b|\btruefrench\b|\bvff\b|\bvfq\b|\bvfi\b|\bvf\b/i},
    {"de", "GERMAN", ~r/\bgerman\b|\bdeutsch\b/i},
    {"es", "SPANISH", ~r/\bspanish\b|\bcastellano\b|\bespanol\b|\blatino\b/i},
    {"it", "ITALIAN", ~r/\bitalian\b|\bitaliano\b|\bita\b/i},
    {"hu", "HUNGARIAN", ~r/\bhungarian\b|\bmagyar\b|\bhun\b/i},
    {"nl", "DUTCH", ~r/\bdutch\b|\bnederlands\b|\bvlaams\b|\bflemish\b/i},
    {"pt", "PORTUGUESE",
     ~r/\bportuguese\b|\bportugues\b|\bportuguesa\b|\bbrazilian\b|\bpt[ ._-]?br\b|\bdublado\b/i},
    {"ru", "RUSSIAN", ~r/\brussian\b|\brus\b/i},
    {"pl", "POLISH", ~r/\bpolish\b|\bpolski\b|\blektor\b/i},
    {"cs", "CZECH", ~r/\bczech\b|\bcesky\b|\bcestina\b/i},
    {"sk", "SLOVAK", ~r/\bslovak\b|\bslovensky\b/i},
    {"sv", "SWEDISH", ~r/\bswedish\b|\bsvenska\b|\bswe\b/i},
    {"da", "DANISH", ~r/\bdanish\b|\bdansk\b/i},
    {"no", "NORWEGIAN", ~r/\bnorwegian\b|\bnorsk\b/i},
    {"fi", "FINNISH", ~r/\bfinnish\b|\bsuomi\b/i},
    {"ro", "ROMANIAN", ~r/\bromanian\b|\bromana\b/i},
    {"bg", "BULGARIAN", ~r/\bbulgarian\b/i},
    {"uk", "UKRAINIAN", ~r/\bukrainian\b|\bukr\b/i},
    {"tr", "TURKISH", ~r/\bturkish\b|\bturkce\b/i},
    {"el", "GREEK", ~r/\bgreek\b/i},
    {"he", "HEBREW", ~r/\bhebrew\b|\bheb\b/i},
    {"ar", "ARABIC", ~r/\barabic\b/i},
    {"hi", "HINDI", ~r/\bhindi\b/i},
    {"ta", "TAMIL", ~r/\btamil\b/i},
    {"te", "TELUGU", ~r/\btelugu\b/i},
    {"ml", "MALAYALAM", ~r/\bmalayalam\b/i},
    {"kn", "KANNADA", ~r/\bkannada\b/i},
    {"bn", "BENGALI", ~r/\bbengali\b/i},
    {"pa", "PUNJABI", ~r/\bpunjabi\b/i},
    {"mr", "MARATHI", ~r/\bmarathi\b/i},
    {"ja", "JAPANESE", ~r/\bjapanese\b|\bjpn\b/i},
    {"ko", "KOREAN", ~r/\bkorean\b|\bkor\b/i},
    {"zh", "CHINESE", ~r/\bchinese\b|\bmandarin\b/i},
    {"cn", "CANTONESE", ~r/\bcantonese\b/i},
    {"th", "THAI", ~r/\bthai\b/i},
    {"vi", "VIETNAMESE", ~r/\bvietnamese\b/i},
    {"id", "INDONESIAN", ~r/\bindonesian\b/i},
    {"fa", "PERSIAN", ~r/\bpersian\b|\bfarsi\b/i},
    # English LAST so a real foreign full word elsewhere in the name wins `first_match` over a
    # title word like "The English Patient".
    {"en", "ENGLISH", ~r/\benglish\b|\beng\b/i}
  ]

  # MULTI is not an ISO language (it means "several audio tracks, incl. the original"). It is matched
  # on the RAW name (before the subtitle strip) so a "MULTI.SUBS" descriptor still tags MULTI, and it
  # wins over any dub language a name also carries.
  @multi ~r/\bmulti\b/i
  @registry_languages Enum.map(@language_registry, fn {_code, tag, re} -> {re, tag} end)

  @language_tags Map.new(@language_registry, fn {code, tag, _re} -> {code, tag} end)

  # A subtitle-LANGUAGE marker — a language token glued by separators to a sub/subs/subtitle(s) word
  # — names the subtitle language, not the audio. Strip it before matching so "FRENCH.SUBS",
  # "ENG.SUBTITLES", "LATINO.SUBS" don't read as an audio tag. Deliberately NOT "subbed"/"subtitled":
  # "KOREAN.SUBBED" means Korean *audio* (subbed = has subtitles), so the language word stays. (A bare
  # "SUB"/"SUBS" with no preceding word, and glued "SUBFRENCH"/"VOSTFR", were already nil.)
  @subtitle ~r/\b[a-z]+[ ._-]*sub(?:s|titles?)?\b/i

  # ISO 639-2 codes `ffprobe` reports for an audio stream's `language` tag, keyed by the registry's
  # 639-1 code — both the bibliographic (B) and terminological (T) forms where they differ
  # ("fre"/"fra", "ger"/"deu", "dut"/"nld"), plus common sub-variants ("nob"/"nno" for Norwegian,
  # "cmn" for Mandarin). Used by the import-time MediaInfo check
  # (`Cinder.Acquisition.Language.audio_satisfies?/2`). `Map.fetch!` below fails the build if a
  # registry language is added here without its codes, so the two can't drift.
  @iso639_2 %{
    "fr" => ["fra", "fre"],
    "de" => ["deu", "ger"],
    "es" => ["spa"],
    "it" => ["ita"],
    "hu" => ["hun"],
    "nl" => ["nld", "dut"],
    "pt" => ["por"],
    "ru" => ["rus"],
    "pl" => ["pol"],
    "cs" => ["ces", "cze"],
    "sk" => ["slk", "slo"],
    "sv" => ["swe"],
    "da" => ["dan"],
    "no" => ["nor", "nob", "nno"],
    "fi" => ["fin"],
    "ro" => ["ron", "rum"],
    "bg" => ["bul"],
    "uk" => ["ukr"],
    "tr" => ["tur"],
    "el" => ["ell", "gre"],
    "he" => ["heb"],
    "ar" => ["ara"],
    "hi" => ["hin"],
    "ta" => ["tam"],
    "te" => ["tel"],
    "ml" => ["mal"],
    "kn" => ["kan"],
    "bn" => ["ben"],
    "pa" => ["pan"],
    "mr" => ["mar"],
    "ja" => ["jpn"],
    "ko" => ["kor"],
    "zh" => ["zho", "chi", "cmn"],
    "cn" => ["yue", "zho", "chi"],
    "th" => ["tha"],
    "vi" => ["vie"],
    "id" => ["ind"],
    "fa" => ["fas", "per"],
    "en" => ["eng"]
  }

  # iso1 => the codes a file's audio stream may carry for that language (the 639-1 code itself plus
  # its 639-2 forms), the accepted set the MediaInfo check matches against. `Map.fetch!` makes a
  # registry language with no `@iso639_2` entry a compile error rather than a silent false-park.
  @audio_codes Map.new(@language_registry, fn {code, _tag, _re} ->
                 {code, [code | Map.fetch!(@iso639_2, code)]}
               end)

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
  Parses `name` into `%{resolution, source, codec, group, language, season, episodes}`. Each
  value is `nil` when no known token matches. A non-binary `name` (e.g. an indexer
  result with a missing title) yields all-`nil` rather than raising, keeping the
  parser total.
  """
  def parse(name) when is_binary(name) do
    {season, episodes} = season_episodes(name)

    %{
      resolution: resolution(name),
      source: source(name),
      codec: first_match(name, @codecs),
      group: group(name),
      language: language(name),
      season: season,
      episodes: episodes
    }
  end

  def parse(_name),
    do: %{
      resolution: nil,
      source: nil,
      codec: nil,
      group: nil,
      language: nil,
      season: nil,
      episodes: nil
    }

  @doc """
  Maps each known TMDB `original_language` code to the release tag the parser emits for it
  (e.g. `"hu" => "HUNGARIAN"`). `Cinder.Acquisition.Language` derives its code↔tag table from
  this so the two never drift — see the `@language_registry` note above.
  """
  def language_tags, do: @language_tags

  @doc """
  Maps each known TMDB `original_language` code to the audio-stream codes a media file may carry
  for it — the 639-1 code plus its ISO 639-2 forms (e.g. `"fr" => ["fr", "fra", "fre"]`). Used by
  `Cinder.Acquisition.Language.audio_satisfies?/2` for the import-time MediaInfo check.
  """
  def audio_codes, do: @audio_codes

  defp resolution(name) do
    down = String.downcase(name)
    Enum.find(@resolutions, &String.contains?(down, &1))
  end

  # A compound source tag (@sources) is unambiguous and matched anywhere; a bare ambiguous token
  # (@bare_sources) is matched only in the tag region so a title word ("Cam", "...Web") can't
  # false-tag a source. The compound match takes precedence (a real "WEBRip" never falls to bare "web").
  defp source(name) do
    first_match(name, @sources) || first_match(tag_region(name), @bare_sources)
  end

  # Everything past the first year/resolution marker (the title precedes it); the whole name when
  # there's no marker. Only the bare ambiguous tokens are scoped to this — compound tags match anywhere.
  defp tag_region(name) do
    case String.split(name, @tag_region_anchor, parts: 2) do
      [_title, tags] -> tags
      [whole] -> whole
    end
  end

  defp first_match(name, table) do
    Enum.find_value(table, fn {pattern, value} -> if Regex.match?(pattern, name), do: value end)
  end

  # MULTI (audio multiplicity) is matched on the raw name so a "MULTI.SUBS" descriptor still tags it;
  # the per-language tags are matched after stripping subtitle markers. A title word that happens to
  # be a language ("The Italian Job") is still matched — that residual collision is netted by the
  # Original/Any soft fallback in `Cinder.Acquisition`, and a real audio tag wins via registry order.
  defp language(name) do
    if Regex.match?(@multi, name),
      do: "MULTI",
      else: first_match(strip_subtitles(name), @registry_languages)
  end

  # Remove subtitle-language markers ("FRENCH.SUBS", "ENG.SUBTITLES", "LATINO.SUBS") so they aren't
  # read as the audio language.
  defp strip_subtitles(name), do: Regex.replace(@subtitle, name, " ")

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
