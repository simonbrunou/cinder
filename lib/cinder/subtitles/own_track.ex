defmodule Cinder.Subtitles.OwnTrack do
  @moduledoc """
  The video's own subtitle track in a wanted language, preferred over a downloaded one
  (`specs/069-subtitle-timing-rules`, option C). It comes with the video, so it is timed to exactly
  this cut: the lines a downloaded file has for a scene the video trims are not in it.

  Only a full dialogue track qualifies: the exact language (an ambiguous generic tag such as "chi"
  for a Cantonese request does not), not forced, and at least #{200} cues, which rules out signs
  and songs tracks. A track that is not for the hearing impaired is preferred, then the longest.
  """

  alias Cinder.Acquisition.Language

  @min_cues 200

  @doc """
  Whether to look at the file's tracks (which reads the whole file) before searching OpenSubtitles.

  At import (`fresh: true`), always: the criteria are built from the record as it was before this
  file landed, so its recorded streams describe the previous file or nothing. The answer is kept
  per file (`Cinder.Subtitles.TrackProbe`), so later sweeps of the same file read it from there.
  Otherwise only when the import probe recorded a stream in `language`. That list also counts
  image-based (PGS) streams, so a match is necessary, not sufficient: `select/2` decides on the
  text tracks.
  """
  @spec wanted?(map(), String.t()) :: boolean()
  def wanted?(%{fresh: true}, _language), do: true

  def wanted?(criteria, language) do
    case Map.get(criteria, :embedded_subtitles) do
      codes when is_list(codes) -> Enum.any?(codes, &Language.exact_track?(language, &1))
      _unknown -> false
    end
  end

  @doc "The best qualifying text track for `language`, or nil."
  @spec select([map()], String.t()) :: map() | nil
  def select(tracks, language) do
    tracks
    |> Enum.filter(fn track ->
      Language.exact_track?(language, track.language) and not track.forced? and
        Map.get(track, :packet_count, 0) >= @min_cues
    end)
    |> Enum.sort_by(fn track ->
      {Map.get(track, :hearing_impaired?, false), -Map.get(track, :packet_count, 0)}
    end)
    |> List.first()
  end
end
