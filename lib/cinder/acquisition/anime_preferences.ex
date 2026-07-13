defmodule Cinder.Acquisition.AnimePreferences do
  @moduledoc """
  Resolves nullable per-title Anime release preferences against global defaults.

  The returned policy is normalized and carries inheritance provenance for the UI.
  """

  alias Cinder.Acquisition.Language

  def resolve(title, defaults) do
    audio_mode = inherited(title.audio_mode, defaults.audio_mode)

    subtitles =
      title.subtitle_languages
      |> inherited_list(defaults.subtitle_languages)
      |> normalize_languages()

    embedded = inherited(title.embedded_subtitle_mode, defaults.embedded_subtitle_mode)

    with {:ok, required_audio} <- required_audio(audio_mode, title),
         :ok <- validate_embedded(embedded, subtitles) do
      {:ok,
       %{
         required_audio_languages: required_audio,
         subtitle_languages: subtitles,
         embedded_subtitle_mode: embedded,
         preferred_groups:
           title.preferred_release_groups
           |> inherited_list(defaults.preferred_groups)
           |> normalize_groups(),
         blocked_groups:
           title.blocked_release_groups
           |> inherited_list(defaults.blocked_groups)
           |> normalize_groups(),
         group_fallback_delay:
           inherited(title.group_fallback_delay, defaults.group_fallback_delay),
         provenance: provenance(title)
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

  defp required_audio(:original, title), do: {:ok, original_languages(title)}
  defp required_audio(:any, _title), do: {:ok, []}

  defp required_audio(:dub, title) do
    with {:ok, dub_language} <- dub_language(title) do
      {:ok, [dub_language]}
    end
  end

  defp required_audio(:dual, title) do
    with {:ok, dub_language} <- dub_language(title) do
      {:ok, Enum.uniq(original_languages(title) ++ [dub_language])}
    end
  end

  defp original_languages(title), do: normalize_languages([title.original_language])

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

  defp inherited(nil, default), do: default
  defp inherited(value, _default), do: value

  defp inherited_list(nil, default), do: default
  defp inherited_list(value, _default), do: value

  defp provenance(title) do
    %{
      audio_mode: source(title.audio_mode),
      subtitle_languages: source(title.subtitle_languages),
      embedded_subtitle_mode: source(title.embedded_subtitle_mode),
      preferred_groups: source(title.preferred_release_groups),
      blocked_groups: source(title.blocked_release_groups),
      group_fallback_delay: source(title.group_fallback_delay)
    }
  end

  defp source(nil), do: :inherited
  defp source(_value), do: :overridden
end
