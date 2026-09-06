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
    # Matched against the forward audio_codes tolerance list, not by re-normalizing each track's
    # code and comparing for equality — "chi"/"zho" (generic Chinese) deliberately also accept a
    # Cantonese target, and equality-after-normalize would break that: normalize/1 pins the
    # generic codes to "zh" (#519), but a "cn" sidecar's own value stays "cn" untouched, so the
    # two would never compare equal even though the accepted forward list still lists them.
    normalized = Language.normalize(language)
    accepted = Map.get(Parser.audio_codes(), normalized, [normalized])

    tracks
    |> Enum.filter(&(String.downcase(&1.language || "") in accepted))
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
