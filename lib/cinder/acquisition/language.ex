defmodule Cinder.Acquisition.Language do
  @moduledoc """
  Per-item preferred-language filtering for release selection.

  A user picks `"original"` / `"french"` / `"any"` per movie/series. This resolves
  the pick to a concrete target language code — using the title's TMDB
  `original_language` for `"original"` — then keeps only releases whose parsed
  `language` satisfies it: a `MULTI` release (multi-audio, includes the original),
  an exact tag match, or — only when the target *is* English — an untagged release.

  An untagged release means **English audio** by scene convention (a non-English
  track is tagged; English is the unmarked default), so it satisfies an English
  target and nothing else. That is the fix for the "untagged assumed to be the
  original" bug — a foreign dub the parser couldn't tag, or a name with no tag, no
  longer passes as a non-English title's "original". `"any"` / an unknown original
  disables the filter. Filter-only: the scorer's ranking is untouched. The code↔tag
  table is derived from `Cinder.Acquisition.Parser` so the two can never drift.
  """
  alias Cinder.Acquisition.Parser
  alias Cinder.Acquisition.Release

  # Single source of truth: the TMDB-code → release-tag map, derived from the parser's registry.
  @tags Parser.language_tags()

  # iso1 → the audio-stream codes a media file may carry for that language (639-1 + 639-2 forms),
  # derived from the same registry. Powers the import-time MediaInfo check.
  @audio_codes Parser.audio_codes()

  # An untagged release is English audio by scene convention (non-English is tagged).
  @default_audio "en"

  @doc """
  Keeps only releases satisfying the resolved target. Returns the list unchanged
  when the filter is inactive (`"any"`, or `"original"` with a blank/nil original).
  """
  def filter(releases, preferred, original) do
    case target(preferred, original) do
      nil -> releases
      t -> Enum.filter(releases, &satisfies?(&1, t))
    end
  end

  @doc "Whether a language filter is active for this preference + original language."
  def active?(preferred, original), do: not is_nil(target(preferred, original))

  @doc """
  Whether an unsatisfiable preference parks the item (an explicit language pick) rather
  than falling back to the unfiltered candidates (the soft Original/Any default).
  """
  def strict?(preferred) when preferred in ["original", "any", nil], do: false
  def strict?(_explicit), do: true

  @doc "Resolves a preference + the title's original language to a target code, or nil (filter off)."
  def target("french", _original), do: "fr"
  def target("original", original), do: presence(original)
  def target(_other, _original), do: nil

  @doc "Whether a single release's parsed language satisfies the resolved target language."
  def satisfies?(%Release{language: "MULTI"}, _target), do: true
  def satisfies?(%Release{language: nil}, target), do: target == @default_audio
  def satisfies?(%Release{language: language}, target), do: language == tag(target)

  @doc """
  Whether a media file's actual audio-track languages (`file_langs`, the codes `ffprobe` reports)
  include the resolved `target` language — the import-time MediaInfo check that backstops the
  name-based filter. Matches a 639-1 `target` against the file's 639-1/639-2 codes via the
  registry-derived table; comparison is case-insensitive. Callers skip the check when `target` is
  nil (an `"any"` pick / unknown original) or when the file reports no language at all.
  """
  def audio_satisfies?(target, file_langs) do
    accepted = Map.get(@audio_codes, target, [target])
    Enum.any?(file_langs, &(String.downcase(&1) in accepted))
  end

  defp tag(code), do: Map.get(@tags, code)

  defp presence(code) when code in [nil, ""], do: nil
  defp presence(code), do: code
end
