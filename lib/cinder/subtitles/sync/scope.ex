defmodule Cinder.Subtitles.Sync.Scope do
  @moduledoc false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Season}
  alias Cinder.Repo

  def units(:library) do
    movies =
      for movie <- Catalog.list_available_movies_with_file(),
          path <- Movie.file_paths(movie),
          do: unit(path, movie.title, [{:movie, movie.id}])

    episodes =
      for episode <- Catalog.list_episodes_with_file(),
          path <- Episode.file_paths(episode),
          do: episode_unit(path, episode, episode.season.series_id)

    merge_units(movies ++ episodes)
  end

  def units({:movie, id}) do
    case Catalog.get_movie_by_id(id) do
      %Movie{file_path: path, title: title} = movie when is_binary(path) ->
        Enum.map(Movie.file_paths(movie), &unit(&1, title, [{:movie, id}]))

      _ ->
        []
    end
  end

  def units({:series, id}) do
    case Catalog.get_series_with_tree(id) do
      nil ->
        []

      series ->
        series.seasons
        |> Enum.flat_map(&episode_units(&1.episodes, id))
        |> merge_units()
    end
  end

  def units({:season, id}) do
    case Repo.get(Season, id) |> preload_episodes() do
      nil -> []
      season -> season.episodes |> episode_units(season.series_id) |> merge_units()
    end
  end

  def units({:episode, id}) do
    case Repo.get(Episode, id) |> preload_episode() do
      nil -> []
      episode -> episode_units([episode], episode.season.series_id)
    end
  end

  defp episode_units(episodes, series_id) do
    for episode <- episodes,
        path <- Episode.file_paths(episode),
        do: episode_unit(path, episode, series_id)
  end

  defp episode_unit(video_path, episode, series_id) do
    unit(video_path, episode_label(episode), [
      {:series, series_id},
      {:season, episode.season_id},
      {:episode, episode.id}
    ])
  end

  defp unit(video_path, label, scopes),
    do: %{video_path: video_path, label: label, scopes: MapSet.new(scopes)}

  defp merge_units(units) do
    {paths, by_path} =
      Enum.reduce(units, {[], %{}}, fn unit, {paths, by_path} ->
        case Map.fetch(by_path, unit.video_path) do
          {:ok, existing} ->
            {paths,
             Map.put(by_path, unit.video_path, %{
               existing
               | scopes: MapSet.union(existing.scopes, unit.scopes)
             })}

          :error ->
            {[unit.video_path | paths], Map.put(by_path, unit.video_path, unit)}
        end
      end)

    paths |> Enum.reverse() |> Enum.map(&Map.fetch!(by_path, &1))
  end

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
