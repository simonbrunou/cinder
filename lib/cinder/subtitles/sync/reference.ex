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
    language = Language.normalize(language)

    tracks
    |> Enum.filter(&(Language.normalize(&1.language) == language))
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
