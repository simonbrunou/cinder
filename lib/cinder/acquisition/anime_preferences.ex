defmodule Cinder.Acquisition.AnimePreferences do
  @moduledoc """
  Resolves the global Anime release policy (from `Cinder.Settings.anime_defaults/0`)
  against a title's own audio-language metadata.

  The A4.5 per-title preference tier stays removed; the one exception (dogfood F4,
  issue #107) is the single-axis `anime_audio_mode` override on a title — effective
  audio mode = the title's override if set, else the global default. Beyond that the
  "policy" is just the global defaults, plus the per-title hard-audio-requirement
  derivation (`:dub`/`:dual` modes need the title's `original_language`/`preferred_language`).
  """

  alias Cinder.Acquisition.Language

  def resolve(title, defaults) do
    audio_mode = Map.get(title, :anime_audio_mode) || defaults.audio_mode

    with {:ok, required_audio} <- required_audio(audio_mode, title),
         :ok <- validate_embedded(defaults.embedded_subtitle_mode, defaults.subtitle_languages) do
      {:ok,
       %{
         audio_mode: audio_mode,
         required_audio_languages: required_audio,
         subtitle_languages: defaults.subtitle_languages,
         embedded_subtitle_mode: defaults.embedded_subtitle_mode,
         preferred_groups: defaults.preferred_groups,
         blocked_groups: defaults.blocked_groups,
         group_fallback_delay: defaults.group_fallback_delay
       }}
    end
  end

  def snapshot(policy, release) do
    %{
      "version" => 1,
      "required_audio_languages" => policy.required_audio_languages,
      "required_embedded_subtitle_languages" =>
        if(policy.embedded_subtitle_mode == :require,
          do: policy.subtitle_languages,
          else: []
        ),
      "release_group" => normalize_group(release.group),
      "release_title" => release.title
    }
  end

  @doc "Whether a frozen release policy is the exact normalized version-1 document."
  def valid_snapshot?(nil, _release_title), do: true

  def valid_snapshot?(snapshot, release_title) when is_map(snapshot) do
    case snapshot do
      %{
        "version" => 1,
        "required_audio_languages" => required_audio,
        "required_embedded_subtitle_languages" => required_subtitles,
        "release_group" => release_group,
        "release_title" => snapshot_title
      } ->
        map_size(snapshot) == 5 and snapshot_title == release_title and
          nonblank_string?(snapshot_title) and normalized_languages?(required_audio) and
          normalized_languages?(required_subtitles) and
          normalized_optional_group?(release_group)

      _invalid ->
        false
    end
  end

  def valid_snapshot?(_snapshot, _release_title), do: false

  @doc "Whether positive Anime release evidence does not contradict the resolved policy."
  def release_allowed?(release, policy), do: verdict(release, policy) == :ok

  @doc "Returns the Anime policy rejection reason used by the manual-search surface."
  def verdict(release, policy) do
    cond do
      group_blocked?(release.group, policy.blocked_groups) ->
        {:rejected, :blocked_anime_group}

      contradictory_audio?(release, policy.required_audio_languages) ->
        {:rejected, :contradictory_audio}

      contradictory_subtitles?(release, policy) ->
        {:rejected, :contradictory_subtitles}

      true ->
        :ok
    end
  end

  @doc "Ascending Anime-only soft preference key; unknown evidence sorts after a positive match."
  def rank_key(release, policy) do
    {
      if(policy.preferred_groups == [] or preferred_group?(release, policy), do: 0, else: 1),
      if(policy.required_audio_languages == [] or explicit_audio_match?(release, policy),
        do: 0,
        else: 1
      ),
      if(
        policy.embedded_subtitle_mode == :allow or policy.subtitle_languages == [] or
          explicit_subtitle_match?(release, policy),
        do: 0,
        else: 1
      )
    }
  end

  @doc "The legacy timing options plus the resolved Anime policy consumed by selection."
  def selection_opts(policy) do
    [
      anime_policy: policy,
      preferred_groups: policy.preferred_groups,
      fallback_delay: policy.group_fallback_delay
    ]
  end

  def normalize_languages(nil), do: []

  def normalize_languages(languages) do
    languages
    |> Enum.map(&Language.normalize/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def normalize_groups(nil), do: []

  def normalize_groups(groups) do
    groups
    |> Enum.map(&normalize_group/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def normalize_group(nil), do: nil
  def normalize_group(group), do: group |> String.trim() |> String.downcase()

  defp normalized_languages?(languages) when is_list(languages) do
    Enum.all?(languages, &nonblank_string?/1) and normalize_languages(languages) == languages
  end

  defp normalized_languages?(_languages), do: false

  defp normalized_optional_group?(nil), do: true

  defp normalized_optional_group?(group) do
    nonblank_string?(group) and normalize_group(group) == group
  end

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp group_blocked?(group, blocked), do: normalize_group(group) in blocked

  defp preferred_group?(release, policy),
    do: normalize_group(release.group) in policy.preferred_groups

  defp contradictory_audio?(%{audio_claim_complete?: true} = release, required)
       when required != [] do
    not Enum.all?(required, &Language.audio_satisfies?(&1, release.audio_languages || []))
  end

  defp contradictory_audio?(_release, _required), do: false

  defp contradictory_subtitles?(release, %{embedded_subtitle_mode: :require} = policy) do
    release.embedded_subtitle_claim == :absent or
      (release.embedded_subtitle_claim == :present and
         release.embedded_subtitle_languages != [] and
         not Enum.any?(policy.subtitle_languages, fn wanted ->
           Language.audio_satisfies?(wanted, release.embedded_subtitle_languages)
         end))
  end

  defp contradictory_subtitles?(_release, _policy), do: false

  defp explicit_audio_match?(release, policy) do
    release.audio_claim_complete? and
      Enum.all?(policy.required_audio_languages, fn wanted ->
        Language.audio_satisfies?(wanted, release.audio_languages || [])
      end)
  end

  defp explicit_subtitle_match?(release, policy) do
    release.embedded_subtitle_claim == :present and
      Enum.any?(policy.subtitle_languages, fn wanted ->
        Language.audio_satisfies?(wanted, release.embedded_subtitle_languages || [])
      end)
  end

  defp required_audio(:original, title), do: {:ok, original_languages(title)}
  defp required_audio(:any, _title), do: {:ok, []}

  defp required_audio(:dub, title) do
    with {:ok, dub_language} <- dub_language(title) do
      {:ok, [dub_language]}
    end
  end

  defp required_audio(:dual, title) do
    with {:ok, dub_language} <- dub_language(title),
         [original_language | _rest] <- original_languages(title) do
      {:ok, Enum.uniq([original_language, dub_language])}
    else
      [] -> {:error, :original_language_required}
      {:error, _reason} = error -> error
    end
  end

  defp original_languages(title) do
    title.original_language
    |> List.wrap()
    |> normalize_languages()
    |> Enum.filter(&Language.known?/1)
  end

  defp dub_language(%{preferred_language: preferred})
       when preferred in [nil, "", "original", "any"],
       do: {:error, :dub_language_required}

  defp dub_language(%{preferred_language: preferred}) do
    case Language.normalize(preferred) do
      "" -> {:error, :dub_language_required}
      normalized -> {:ok, normalized}
    end
  end

  defp validate_embedded(:require, []), do: {:error, :subtitle_language_required}
  defp validate_embedded(_mode, _languages), do: :ok
end
