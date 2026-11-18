defmodule Cinder.Subtitles.WantedLanguage do
  @moduledoc """
  What counts as a wanted subtitle language, and the language a sidecar's file name carries
  (#1415).

  A wanted code is a subtitle language from Settings, as `Cinder.Subtitles.wanted_languages/0`
  gives it: free text, trimmed and downcased, such as `fr`, `fra`, `pt-br` or `cn`. That text
  names the fetched sidecar (`sidecar_path/2`) and keys its manifest entry. This module reads it
  in two ways, and they stay apart:

  - Against an embedded track (`track/2`), the whole code. A wanted code with a subtag takes only
    a track with that whole code, separator included: wanted `pt-br` takes a `pt-BR` track but no
    `por`, `pt-PT` or `pt_BR` one, and `zh-hant` takes a `zh-Hant` track but no `zh` one.
  - Against a sidecar's file name (`sidecar?/2`), the part before a `-` or `_` subtag. Wanted
    `pt-br` takes `M.pt.srt` and `M.pt-PT.srt`, and `zh-hant` takes `M.zh.srt` (#1309).

  The generic Chinese `chi` and `zho` count for Mandarin `zh` and for Cantonese `cn` alike, in a
  track code or a sidecar name (#573, #1343). A track tagged so is a weaker match than a track
  with a code unique to the language (`:tolerated`, not `:exact`); `sidecar?/2` gives a sidecar
  name no such rank. Mandarin's own `cmn` never counts for `cn`.

  A sidecar's file name carries the language `name_language/1` reads, which names a release
  sidecar placed next to an imported video (`placed_path/2`): a generic Chinese `M.chi.srt` is
  placed as `<video>.zh.srt` (#1343, #1391).
  """

  alias Cinder.Acquisition.Language

  @flags ~w(forced sdh cc hi)

  # `hi` is both the hearing-impaired flag and ISO-639-1 Hindi. Read it as a flag when the name
  # carries another language, and as the language when it carries none — otherwise `Movie.hi.srt`
  # is unnameable, since Hindi has no other ISO-639-1 spelling (issue #201). `sdh` is the
  # unambiguous hearing-impaired token and stays a flag always, so preferring the language reading
  # in the conflict loses nothing.
  @ambiguous_flags ~w(hi)

  @doc """
  How a track's raw language code, as the media file reports it, counts for `wanted`: `:exact`
  for a code unique to the language, `:tolerated` for a generic Chinese `chi` or `zho` that
  Mandarin and Cantonese share, `nil` for none. The code is matched raw, never normalized first:
  normalizing `chi` to `zh` would lose the difference. A full language name such as `French`
  counts as its code. A track with no code counts for nothing.
  """
  @spec track(String.t(), String.t() | nil) :: :exact | :tolerated | nil
  def track(wanted, code) do
    cond do
      Language.exact_track?(wanted, code) -> :exact
      Language.raw_track_satisfies?(wanted, code) -> :tolerated
      true -> nil
    end
  end

  @doc """
  Whether a sidecar whose file name is `path` counts as `wanted`. The wanted code's part before a
  subtag must read as the language the name carries (`name_language/1`), or tolerate the code
  the name writes: a wanted Cantonese `cn` takes a generic Chinese `M.chi.srt`, which reads as
  `zh`, and refuses an explicit `M.zh.srt` (#1343). A name that carries no language reads as
  `und`, which only a wanted `und` takes.
  """
  @spec sidecar?(String.t(), Path.t()) :: boolean()
  def sidecar?(wanted, path) do
    [base | _subtag] = String.split(wanted, ["-", "_"], parts: 2)
    {language, _flags, written, _subtag?} = classify(path)

    Language.normalize(base) == language or
      (is_binary(written) and Language.raw_track_satisfies?(base, written))
  end

  @doc "The fetched sidecar of `wanted` for `video_path`: `<video>.<wanted code>.srt`."
  @spec sidecar_path(Path.t(), String.t()) :: Path.t()
  def sidecar_path(video_path, wanted) do
    dir = Path.dirname(video_path)
    base = Path.basename(video_path, Path.extname(video_path))
    Path.join(dir, "#{base}.#{wanted}.srt")
  end

  @doc """
  Where a release sidecar at `path` is placed next to `dest_video`, in the media server's
  `<video>.<language>[.flag...].<ext>` convention: the language `name_language/1` reads, the
  flags `name_flags/1` reads in name order, and the extension downcased.
  """
  @spec placed_path(Path.t(), Path.t()) :: Path.t()
  def placed_path(path, dest_video) do
    {language, flags, _written, _subtag?} = classify(path)
    flag = Enum.map_join(flags, &".#{&1}")
    "#{Path.rootname(dest_video)}.#{language}#{flag}#{String.downcase(Path.extname(path))}"
  end

  @doc """
  The ISO 639-1 code a sidecar's file name carries, with its flags stripped, or `"und"` for none
  or a code the registry does not know. A language with a region or script subtag reads as its
  base language: `fr-FR` reads as `fr`. A code or tag name reads as
  `Cinder.Acquisition.Language.normalize/1` gives it, so the generic Chinese `chi` and `zho` read
  as `zh` (#1343).
  """
  @spec name_language(Path.t()) :: String.t()
  def name_language(path), do: path |> classify() |> elem(0)

  @doc """
  Flags (`forced`, `sdh`, `cc`, `hi`) from the trailing run of flag and language tokens of a
  sidecar's file name, in name order; a `hi` that `name_language/1` reads as Hindi is not one.
  """
  @spec name_flags(Path.t()) :: [String.t()]
  def name_flags(path), do: path |> classify() |> elem(1)

  @doc """
  How a sidecar's file name writes the language `name_language/1` reads, best first:

  1. the code it reads as, which `placed_path/2` writes, with no subtag: `M.zh.srt`, `M.cn.srt`;
  2. another code or a name for that language, with no subtag: `M.chi.srt`, `M.fre.srt`;
  3. the language with a region or script subtag: `M.zh-Hans.srt`, `M.fr-FR.srt`, `M.chi-TW.srt`.

  A name that carries no language ranks `1`. Case never changes the rank: `M.ZH.srt` ranks `1`.
  `Cinder.Library.Sidecars.link_listed/2` tries the release sidecars that take one placed name
  best-ranked first (#1416).
  """
  @spec name_rank(Path.t()) :: 1 | 2 | 3
  def name_rank(path) do
    case classify(path) do
      {"und", _flags, _written, _subtag?} -> 1
      {_language, _flags, _written, true} -> 3
      {language, _flags, language, false} -> 1
      {_language, _flags, _written, false} -> 2
    end
  end

  # `{language, flags, written, subtag?}`: the language, the flags, the language code as the name
  # writes it, downcased and without its subtag, or `nil` when the language reads `und`, and
  # whether the name writes a subtag after that code. One decision for all of them, so a `hi`
  # consumed as the language can't ALSO be re-emitted as a flag by placed_path/2, which would name
  # a Hindi sidecar `<stem>.hi.hi.srt`.
  defp classify(path) do
    tokens =
      path
      |> Path.basename()
      |> Path.rootname()
      |> String.split(".")
      |> Enum.map(&String.downcase/1)

    flags = trailing_flags(tokens)

    case resolve(tokens, @flags) do
      nil -> ambiguous_reading(tokens, flags)
      {language, code, subtag?} -> {language, flags, code, subtag?}
    end
  end

  # A flag word is a flag only in the name's trailing run of flag and language tokens, which the
  # first token that is neither ends (#1087). Before it, the word belongs to the title or a release
  # tag: `Forced.Entry.1983…fr.srt` and `Hi.Mom.2021…fr.srt` are full French subtitles, and
  # `Movie.1960.CC…en.srt` carries the Criterion Collection's tag. The language reading needs no
  # such limit: the last non-flag token lies inside the run whenever it is a language.
  defp trailing_flags(tokens) do
    tokens
    |> Enum.reverse()
    |> Enum.take_while(&(&1 in @flags or read_token(&1) != nil))
    |> Enum.filter(&(&1 in @flags))
    |> Enum.reverse()
  end

  # Nothing resolved with every flag stripped, so retry letting the ambiguous ones be languages.
  # The retry finds a language only when the last token that is not `forced`, `sdh` or `cc` is a
  # `hi`, i.e. exactly the shadowed case. Only those flags follow that `hi`, so it sits in the
  # trailing run and `flags` holds it.
  defp ambiguous_reading(tokens, flags) do
    case resolve(tokens, @flags -- @ambiguous_flags) do
      nil -> {"und", flags, nil, false}
      {language, code, subtag?} -> {language, flags -- @ambiguous_flags, code, subtag?}
    end
  end

  defp resolve(tokens, strip) do
    case tokens |> Enum.reject(&(&1 in strip)) |> List.last() do
      nil -> nil
      token -> read_token(token)
    end
  end

  # `{language, code, subtag?}`: the language the token reads as, the code it writes for it, and
  # whether a subtag follows that code.
  defp read_token(token), do: code_reading(token, false) || regional_language(token)

  defp code_reading(code, subtag?) do
    case Language.lookup(code) do
      nil -> nil
      language -> {language, code, subtag?}
    end
  end

  # A language with one region or script subtag, joined by `-` or `_` (`fr-FR`, `pt_BR`,
  # `es-419`, `zh-Hant`), reads as its base language (#1309). The subtag is 2 letters, 3 digits
  # or 4 letters, so a release tag such as `x264-GRP` or `WEB-DL` stays no language.
  defp regional_language(token) do
    case Regex.run(~r/\A([^-_]+)[-_](?:[a-z]{2}|[0-9]{3}|[a-z]{4})\z/, token) do
      [_token, base] -> code_reading(base, true)
      nil -> nil
    end
  end
end
