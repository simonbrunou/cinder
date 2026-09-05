defmodule Cinder.Subtitles.Sync.Scope do
  @moduledoc false

  import Ecto.Query

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

  @doc """
  The single unit owning `video_path`, resolved by a targeted query instead of loading the whole
  catalog (issue #525) — `enqueue_after_download/3` calls this while a per-video lock is held, so
  the O(S*N) full movie/episode scan `units(:library)` did there for every provider commit
  mattered. `nil` when no available movie or filed episode owns this path.
  """
  @spec unit_for_video_path(String.t(), :movies | :tv) :: map() | nil
  def unit_for_video_path(video_path, :movies) do
    case find_movie(video_path) do
      nil -> nil
      movie -> unit(video_path, movie.title, [{:movie, movie.id}])
    end
  end

  def unit_for_video_path(video_path, :tv) do
    case find_episodes(video_path) do
      [] -> nil
      episodes -> merge_episode_unit(video_path, episodes)
    end
  end

  defp find_movie(video_path) do
    Movie
    |> where([m], m.status == :available and m.file_path == ^video_path)
    |> Repo.one()
    |> Kernel.||(find_movie_by_part(video_path))
  end

  # `part_file_paths` is a JSON-serialized list, "never queried independently" by design (see the
  # migration that added it) — narrowed here to movies that actually have one before scanning
  # client-side, so an ordinary single-file library never runs this query at all.
  defp find_movie_by_part(video_path) do
    Movie
    |> where([m], m.status == :available and fragment("? != '[]'", m.part_file_paths))
    |> Repo.all()
    |> Enum.find(&(video_path in &1.part_file_paths))
  end

  # A combined double-episode file (e.g. a season-pack "S01E05E06.mkv") is a supported case in
  # the import pipeline: `file_path` names the same file for two separate episode rows. `all/2`
  # (not `one/2`/`get_by/2`, which raise on more than one match) collects every owner so the unit
  # carries every episode's scope, matching what `units(:library)`'s merge_units/1 already does
  # for this exact case — a single-owner lookup would otherwise drop or crash on the second one.
  defp find_episodes(video_path) do
    case Repo.all(from(e in Episode, where: e.file_path == ^video_path, preload: :season)) do
      [] -> find_episodes_by_part(video_path)
      episodes -> episodes
    end
  end

  defp find_episodes_by_part(video_path) do
    Episode
    |> where([e], fragment("? != '[]'", e.part_file_paths))
    |> preload(:season)
    |> Repo.all()
    |> Enum.filter(&(video_path in &1.part_file_paths))
  end

  defp merge_episode_unit(video_path, [primary | _] = episodes) do
    scopes = episodes |> Enum.flat_map(&episode_scopes/1) |> MapSet.new()
    unit(video_path, episode_label(primary), MapSet.to_list(scopes))
  end

  defp episode_scopes(episode) do
    [
      {:series, episode.season.series_id},
      {:season, episode.season_id},
      {:episode, episode.id}
    ]
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
