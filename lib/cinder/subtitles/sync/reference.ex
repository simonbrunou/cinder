defmodule Cinder.Subtitles.Sync.Reference do
  @moduledoc false

  alias Cinder.Acquisition.Language

  def resolver(nil, _video_path), do: &audio/1

  def resolver(media_info, video_path) do
    case media_info.subtitle_tracks(video_path) do
      {:ok, tracks} -> &select(media_info, video_path, tracks, &1)
      _ -> &audio/1
    end
  end

  defp select(media_info, video_path, tracks, language) do
    # Language.raw_track_satisfies?/2 — a track's RAW (un-normalized) code against the forward
    # tolerance list — not equality-after-normalize: a "cn" (Cantonese) target must still accept
    # a generically-tagged "chi"/"zho" track, while correctly excluding an explicitly Mandarin
    # "cmn" one (#519, #573). Cinder.Library.MediaInfo.Ffprobe.subtitle_language/1 reports the raw
    # code for exactly this reason — never canonicalize &1.language before this comparison.
    tracks
    |> Enum.filter(&Language.raw_track_satisfies?(language, &1.language))
    |> Enum.reject(&Map.get(&1, :forced?, false))
    |> Enum.sort_by(&Map.get(&1, :packet_count, 0), :desc)
    |> Enum.find_value({:audio, nil}, fn track ->
      case media_info.extract_subtitle(video_path, track.index) do
        {:ok, content} when is_binary(content) -> {:embedded, {:content, content}}
        _ -> nil
      end
    end)
  end

  defp audio(_language), do: {:audio, nil}
end
