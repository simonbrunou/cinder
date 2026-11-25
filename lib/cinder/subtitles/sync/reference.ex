defmodule Cinder.Subtitles.Sync.Reference do
  @moduledoc false

  alias Cinder.Subtitles.WantedLanguage

  def resolver(nil, _video_path), do: &audio/1

  def resolver(media_info, video_path) do
    case media_info.subtitle_tracks(video_path) do
      {:ok, tracks} -> &select(media_info, video_path, tracks, &1)
      _ -> &audio/1
    end
  end

  defp select(media_info, video_path, tracks, language) do
    # WantedLanguage.track/2 reads a track's RAW (un-normalized) code, not equality after
    # normalizing: a wanted "cn" (Cantonese) must still accept a generically-tagged "chi"/"zho"
    # track, while correctly excluding an explicitly Mandarin "cmn" one (#519, #573).
    # Cinder.Library.MediaInfo.Ffprobe.subtitle_language/1 reports the raw code for exactly this
    # reason: never canonicalize &1.language before this comparison.
    tracks
    |> Enum.filter(&(WantedLanguage.track(language, &1.language) != nil))
    |> Enum.reject(&Map.get(&1, :forced?, false))
    # An unambiguous match (an explicit "cn"/"yue" or "zh"/"cmn" tag) beats a generic-alias one
    # ("chi"/"zho", tolerated by both) regardless of packet count - the ambiguous track might
    # genuinely be the other language (#573 review). Likewise a "pt-BR" track is tried before a
    # "por" one, which a wanted "pt-br" only tolerates (#1434). Packet count still breaks ties
    # within the same exactness tier.
    |> Enum.sort_by(
      &{if(WantedLanguage.track(language, &1.language) == :exact, do: 0, else: 1),
       -Map.get(&1, :packet_count, 0)}
    )
    |> Enum.find_value({:audio, nil}, fn track ->
      case media_info.extract_subtitle(video_path, track.index) do
        {:ok, content} when is_binary(content) -> {:embedded, {:content, content}}
        _ -> nil
      end
    end)
  end

  defp audio(_language), do: {:audio, nil}
end
