defmodule Cinder.Subtitles.Sync.Reference do
  @moduledoc false

  alias Cinder.Acquisition.{Language, Parser}

  def resolver(nil, _video_path), do: &audio/1

  def resolver(media_info, video_path) do
    case media_info.subtitle_tracks(video_path) do
      {:ok, tracks} -> &select(media_info, video_path, tracks, &1)
      _ -> &audio/1
    end
  end

  defp select(media_info, video_path, tracks, language) do
    # Every real MediaInfo implementation reports an already-canonicalized track language
    # (Cinder.Library.MediaInfo.Ffprobe.subtitle_language/1 calls Language.normalize/1 too), so
    # "chi"/"zho" never reach here as raw alias strings — they arrive as "zh". A "cn" (Cantonese)
    # target's forward tolerance list still lists the raw aliases ("cn", "yue", "zho", "chi"), so
    # each of THOSE is normalized too before comparison: "zh" then legitimately satisfies a "cn"
    # target (a generically-tagged Cantonese track), while a "yue"/"cn"-tagged track (which stays
    # "cn" after normalization, unambiguous) still does too. Comparing raw alias strings against
    # an already-canonical track language would never match at all (#519).
    accepted =
      language
      |> Language.normalize()
      |> then(&Map.get(Parser.audio_codes(), &1, [&1]))
      |> Enum.map(&Language.normalize/1)
      |> Enum.uniq()

    tracks
    |> Enum.filter(&(Language.normalize(&1.language) in accepted))
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
