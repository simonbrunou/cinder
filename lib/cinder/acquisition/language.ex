defmodule Cinder.Acquisition.Language do
  @moduledoc """
  Per-item preferred-language filtering for release selection.

  A user picks `"original"` / `"french"` / `"dual"` / `"any"` per movie/series (the single
  per-title Audio pick — it also drives the Anime audio mode, see
  `Cinder.Acquisition.AnimePreferences`). This resolves the pick to a concrete target language
  code — using the title's TMDB `original_language` for `"original"`, and `"fr"` for `"dual"`
  same as `"french"` (the stricter both-tracks guarantee is an Anime-only feature) — then keeps
  only releases whose parsed `language` satisfies it: a `MULTI` release (multi-audio, includes
  the original), an exact tag match, or — only when the target *is* English — an untagged
  release.

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

  @language_aliases @audio_codes
                    |> Enum.flat_map(fn {canonical, aliases} ->
                      Enum.map(aliases, &{&1, canonical})
                    end)
                    |> Map.new()

  @language_aliases Map.merge(
                      @language_aliases,
                      Map.new(@tags, fn {canonical, tag} ->
                        {String.downcase(tag), canonical}
                      end)
                    )

  # Every audio code known for any language — lets `audio_satisfies?/2` tell a *recognised* wrong
  # language (park) from a code it doesn't recognise (could be a variant of the target; don't park).
  @known_audio_codes @audio_codes |> Map.values() |> List.flatten() |> MapSet.new()

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

  @doc "The valid `preferred_language` values (the per-title Audio picks)."
  def preferences, do: ["original", "french", "dual", "any"]

  @doc "Normalizes a language code or known parser tag to its ISO 639-1 code."
  def normalize(nil), do: nil

  def normalize(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.downcase()
    Map.get(@language_aliases, normalized, normalized)
  end

  @doc "Whether a value normalizes to a language supported by the release and stream registry."
  def known?(code), do: normalize(code) in Map.keys(@audio_codes)

  @doc """
  Whether an unsatisfiable preference parks the item (an explicit language pick) rather
  than falling back to the unfiltered candidates (the soft Original/Any default).
  """
  def strict?(preferred) when preferred in ["original", "any", nil], do: false
  def strict?(_explicit), do: true

  @doc "Resolves a preference + the title's original language to a target code, or nil (filter off)."
  def target("french", _original), do: "fr"
  def target("dual", _original), do: "fr"
  def target("original", original), do: presence(original)
  def target(_other, _original), do: nil

  @doc "Whether a single release's parsed language satisfies the resolved target language."
  def satisfies?(%Release{language: language}, target), do: satisfies_lang?(language, target)

  @doc "Whether a raw parsed language code satisfies the target (no %Release{} needed). nil target = true."
  def satisfies_lang?(_code, nil), do: true
  def satisfies_lang?("MULTI", _target), do: true
  def satisfies_lang?(code, target) when code in [nil, ""], do: target == @default_audio
  def satisfies_lang?(code, target), do: code == tag(target)

  @doc """
  Whether a media file's audio tracks are compatible with the resolved `target` language — the
  import-time MediaInfo check that backstops the name-based filter (callers skip it when `target`
  is nil or the file reports no language).

  Conservative on purpose: it returns `false` (a confirmed mismatch → the importer parks) ONLY when
  `target` is a known language AND the file positively names a *recognised other* language. A target
  outside the registry, a file code we don't recognise (a 639-2 variant we don't list, junk), or a
  full-word tag all return `true` — so a correctly-languaged file is never parked, only a file whose
  audio is provably a different known language.
  """
  def audio_satisfies?(_target, []), do: true

  def audio_satisfies?(target, file_langs) do
    case Map.get(@audio_codes, target) do
      nil ->
        true

      accepted ->
        langs = Enum.map(file_langs, &String.downcase/1)
        # Satisfied if the target is present, OR any track carries a code we don't recognise (it
        # could be an unlisted variant of the target). Park only when EVERY track is a recognised
        # *other* language — never on incomplete data.
        Enum.any?(langs, &(&1 in accepted)) or Enum.any?(langs, &(&1 not in @known_audio_codes))
    end
  end

  @doc """
  Classifies whether tagged streams satisfy a required language without collapsing incomplete
  evidence into a match or mismatch.
  """
  def stream_status(required, present, unknown?) do
    required = normalize(required)
    accepted = [required | Map.get(@audio_codes, required, [])]
    present = Enum.map(present, &String.downcase/1)

    cond do
      Enum.any?(present, &(&1 in accepted)) -> :satisfied
      unknown? or Enum.any?(present, &(&1 not in @known_audio_codes)) -> :unknown
      true -> :mismatch
    end
  end

  defp tag(code), do: Map.get(@tags, code)

  defp presence(code) when code in [nil, ""], do: nil
  defp presence(code), do: code
end
