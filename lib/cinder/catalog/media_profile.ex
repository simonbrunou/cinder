defmodule Cinder.Catalog.MediaProfile do
  @moduledoc "Selected and effective media-profile policy with bounded weak evidence."

  def summary(record, extra_evidence \\ [])

  def summary(%{media_profile: :anime}, _extra_evidence) do
    %{selected: :anime, effective: :anime, suggestion: nil, evidence: [:explicit_anime]}
  end

  def summary(%{media_profile: :standard}, _extra_evidence) do
    %{selected: :standard, effective: :standard, suggestion: nil, evidence: [:explicit_standard]}
  end

  def summary(record, extra_evidence) do
    evidence = weak_evidence(record, extra_evidence)

    %{
      selected: :auto,
      effective: :standard,
      suggestion: if(evidence == [], do: nil, else: :anime),
      evidence: evidence
    }
  end

  defp weak_evidence(record, extra_evidence) do
    japanese_animation =
      if record.original_language == "ja" and "Animation" in (record.genres || []),
        do: [:japanese_animation],
        else: []

    Enum.filter(
      [:japanese_animation, :absolute_episode_group],
      &(&1 in japanese_animation or &1 in extra_evidence)
    )
  end
end
