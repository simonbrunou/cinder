defmodule Cinder.Subtitles.Sync.Scope do
  @moduledoc false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season}
  alias Cinder.Repo

  def units(:library) do
    movies =
      for movie <- Catalog.list_available_movies_with_file(),
          do: unit(movie.file_path, movie.title)

    episodes =
      for episode <- Catalog.list_episodes_with_file(),
          path <- Episode.file_paths(episode),
          do: unit(path, episode_label(episode))

    Enum.uniq_by(movies ++ episodes, & &1.video_path)
  end

  def units({:movie, id}) do
    case Catalog.get_movie_by_id(id) do
      %{file_path: path, title: title} when is_binary(path) -> [unit(path, title)]
      _ -> []
    end
  end

  def units({:series, id}) do
    case Catalog.get_series_with_tree(id) do
      nil -> []
      series -> series.seasons |> Enum.flat_map(&episode_units(&1.episodes))
    end
  end

  def units({:season, id}) do
    case Repo.get(Season, id) |> preload_episodes() do
      nil -> []
      season -> episode_units(season.episodes)
    end
  end

  def units({:episode, id}) do
    case Repo.get(Episode, id) |> preload_episode() do
      nil -> []
      episode -> episode_units([episode])
    end
  end

  defp episode_units(episodes) do
    for episode <- episodes,
        path <- Episode.file_paths(episode),
        do: unit(path, episode_label(episode))
  end

  defp unit(video_path, label), do: %{video_path: video_path, label: label}

  defp episode_label(%{season: %{season_number: season}, episode_number: episode, title: title}),
    do: "S#{pad2(season)}E#{pad2(episode)} · #{title}"

  defp episode_label(%{episode_number: episode, title: title}),
    do: "E#{pad2(episode)} · #{title}"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
  defp preload_episodes(nil), do: nil
  defp preload_episodes(season), do: Repo.preload(season, episodes: :season)
  defp preload_episode(nil), do: nil
  defp preload_episode(episode), do: Repo.preload(episode, :season)
end
