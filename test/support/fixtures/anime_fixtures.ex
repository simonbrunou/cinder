defmodule Cinder.AnimeFixtures do
  @moduledoc """
  Test helpers for the anime acquisition rules.
  """

  @doc """
  A resolved anime policy (`Cinder.Acquisition.AnimePreferences.resolve/2`'s map) that contradicts
  nothing: no required audio or subtitles, no preferred or blocked group, a one-day group wait. A
  test overrides only the rule it exercises.
  """
  def neutral_anime_policy(overrides \\ []) do
    Map.merge(
      %{
        required_audio_languages: [],
        subtitle_languages: [],
        embedded_subtitle_mode: :allow,
        preferred_groups: [],
        blocked_groups: [],
        group_fallback_delay: 86_400
      },
      Map.new(overrides)
    )
  end
end
