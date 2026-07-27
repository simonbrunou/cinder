defmodule Cinder.Library.MigrationReconciler do
  @moduledoc """
  Pure reconciliation from migration-source records to Cinder's TMDB identities.

  Lookups are keyed exactly like `Cinder.Catalog.TMDB.find_by_external_id/2` calls:
  `{external_source, external_id} => {:ok, results} | {:error, reason}`.
  """

  alias Cinder.Library.MigrationSource

  @type lookup_key :: {:imdb_id | :tvdb_id, String.t() | integer()}
  @type lookups :: %{optional(lookup_key()) => {:ok, [map()]} | {:error, term()}}

  @type unresolved_reason ::
          :missing_external_id
          | :lookup_missing
          | :no_match
          | :multiple_matches
          | :series_unresolved
          | {:lookup_failed, term()}
          | {:wrong_series, integer(), integer() | nil}

  @type unresolved :: %{
          required(:kind) => :movie | :series | :episode,
          required(:provider_id) => MigrationSource.provider_id(),
          required(:reason) => unresolved_reason()
        }

  @type coordinate :: %{
          required(:source) => String.t(),
          required(:scheme) => String.t(),
          required(:namespace) => String.t(),
          required(:canonical_value) => String.t(),
          required(:precedence) => :inferred
        }

  @type resolved_movie :: %{
          required(:provider_id) => MigrationSource.provider_id(),
          required(:tmdb_id) => pos_integer(),
          required(:imdb_id) => String.t() | nil,
          required(:file_id) => MigrationSource.provider_id() | nil
        }

  @type resolved_series :: %{
          required(:provider_id) => MigrationSource.provider_id(),
          required(:tvdb_id) => pos_integer(),
          required(:tmdb_id) => pos_integer()
        }

  @type resolved_episode :: %{
          required(:provider_id) => MigrationSource.provider_id(),
          required(:series_id) => MigrationSource.provider_id(),
          required(:tvdb_id) => pos_integer(),
          required(:season_number) => non_neg_integer(),
          required(:episode_number) => non_neg_integer(),
          required(:file_id) => MigrationSource.provider_id() | nil,
          required(:tmdb_episode_id) => pos_integer(),
          required(:series_tmdb_id) => pos_integer(),
          required(:coordinates) => [coordinate()]
        }

  @type coordinate_batch :: %{
          required(:series_provider_id) => MigrationSource.provider_id(),
          required(:series_tmdb_id) => pos_integer(),
          required(:source) => String.t(),
          required(:namespace) => String.t(),
          required(:scheme) => String.t(),
          required(:coordinates) => [
            %{
              required(:scheme) => String.t(),
              required(:canonical_value) => String.t(),
              required(:precedence) => :inferred,
              required(:episode_ids) => [pos_integer()]
            }
          ]
        }

  @type result :: %{
          required(:movies) => [resolved_movie()],
          required(:series) => [resolved_series()],
          required(:episodes) => [resolved_episode()],
          required(:files) => [MigrationSource.file()],
          required(:unresolved) => [unresolved()]
        }

  @doc """
  Resolves every snapshot record independently and retains unresolved records with a reason.

  A TVDB episode is accepted only when `/find` returns exactly one episode belonging to the
  already-resolved parent series. Each resolved episode carries both its direct TVDB id and
  aired-number coordinate; multiple source episodes may intentionally share one TMDB episode id.
  """
  @spec reconcile(MigrationSource.snapshot(), lookups()) :: result()
  def reconcile(snapshot, lookups) do
    {movies, movie_errors} = resolve_all(snapshot.movies, :movie, &resolve_movie(&1, lookups))
    {series, series_errors} = resolve_all(snapshot.series, :series, &resolve_series(&1, lookups))
    series_by_provider_id = Map.new(series, &{&1.provider_id, &1})

    {episodes, episode_errors} =
      resolve_all(
        snapshot.episodes,
        :episode,
        &resolve_episode(&1, series_by_provider_id, lookups)
      )

    %{
      movies: movies,
      series: series,
      episodes: episodes,
      files: snapshot.files,
      unresolved: movie_errors ++ series_errors ++ episode_errors
    }
  end

  @doc """
  Converts resolved episode coordinates into batches accepted by
  `Cinder.Catalog.Identity.replace_provider_coordinates/5`.

  The caller supplies the explicit TMDB-episode-id to Cinder episode primary-key index. Missing
  Cinder identities fail the whole conversion rather than silently dropping a coordinate.
  """
  @spec coordinate_batches(result(), %{required(pos_integer()) => pos_integer()}) ::
          {:ok, [coordinate_batch()]} | {:error, {:cinder_episode_not_found, pos_integer()}}
  def coordinate_batches(%{episodes: episodes}, cinder_episode_ids) do
    with {:ok, rows} <- coordinate_rows(episodes, cinder_episode_ids) do
      batches =
        rows
        |> Enum.group_by(fn {episode, coordinate, _episode_id} ->
          {
            episode.series_id,
            episode.series_tmdb_id,
            coordinate.source,
            coordinate.namespace,
            coordinate.scheme
          }
        end)
        |> Enum.map(fn
          {{series_id, series_tmdb_id, source, namespace, scheme}, grouped} ->
            %{
              series_provider_id: series_id,
              series_tmdb_id: series_tmdb_id,
              source: source,
              namespace: namespace,
              scheme: scheme,
              coordinates:
                Enum.map(grouped, fn {_episode, coordinate, episode_id} ->
                  %{
                    scheme: coordinate.scheme,
                    canonical_value: coordinate.canonical_value,
                    precedence: coordinate.precedence,
                    episode_ids: [episode_id]
                  }
                end)
            }
        end)
        |> Enum.sort_by(&{&1.series_provider_id, &1.scheme})

      {:ok, batches}
    end
  end

  defp resolve_all(records, kind, resolve) do
    records
    |> Enum.reduce({[], []}, fn record, {resolved, unresolved} ->
      case resolve.(record) do
        {:ok, identity} ->
          {[identity | resolved], unresolved}

        {:error, reason} ->
          {resolved,
           [%{kind: kind, provider_id: record.provider_id, reason: reason} | unresolved]}
      end
    end)
    |> then(fn {resolved, unresolved} ->
      {Enum.reverse(resolved), Enum.reverse(unresolved)}
    end)
  end

  defp resolve_movie(%{tmdb_id: tmdb_id} = movie, _lookups)
       when is_integer(tmdb_id) and tmdb_id > 0,
       do: {:ok, movie}

  defp resolve_movie(%{imdb_id: imdb_id} = movie, lookups)
       when is_binary(imdb_id) and imdb_id != "" do
    with {:ok, match} <- unique_match(lookups, {:imdb_id, imdb_id}, :movie) do
      {:ok, %{movie | tmdb_id: match.tmdb_id}}
    end
  end

  defp resolve_movie(_movie, _lookups), do: {:error, :missing_external_id}

  defp resolve_series(%{tvdb_id: tvdb_id} = series, lookups)
       when is_integer(tvdb_id) and tvdb_id > 0 do
    with {:ok, match} <- unique_match(lookups, {:tvdb_id, tvdb_id}, :tv) do
      {:ok, Map.put(series, :tmdb_id, match.tmdb_id)}
    end
  end

  defp resolve_series(_series, _lookups), do: {:error, :missing_external_id}

  defp resolve_episode(episode, series_by_provider_id, lookups) do
    with {:ok, series} <- fetch_series(series_by_provider_id, episode.series_id),
         {:ok, tvdb_id} <- external_id(episode.tvdb_id),
         {:ok, match} <- unique_match(lookups, {:tvdb_id, tvdb_id}, :episode),
         :ok <- same_series(match, series.tmdb_id) do
      {:ok,
       episode
       |> Map.put(:tmdb_episode_id, match.tmdb_episode_id)
       |> Map.put(:series_tmdb_id, series.tmdb_id)
       |> Map.put(:coordinates, episode_coordinates(episode, series))}
    end
  end

  defp fetch_series(series_by_provider_id, provider_id) do
    case Map.fetch(series_by_provider_id, provider_id) do
      {:ok, series} -> {:ok, series}
      :error -> {:error, :series_unresolved}
    end
  end

  defp external_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp external_id(_id), do: {:error, :missing_external_id}

  defp unique_match(lookups, key, kind) do
    case Map.fetch(lookups, key) do
      :error ->
        {:error, :lookup_missing}

      {:ok, {:error, reason}} ->
        {:error, {:lookup_failed, reason}}

      {:ok, {:ok, results}} when is_list(results) ->
        results
        |> Enum.filter(&match_kind?(&1, kind))
        |> unique_result()
    end
  end

  defp unique_result([]), do: {:error, :no_match}
  defp unique_result([match]), do: {:ok, match}
  defp unique_result(_matches), do: {:error, :multiple_matches}

  defp match_kind?(%{type: :movie, tmdb_id: id}, :movie), do: valid_id?(id)
  defp match_kind?(%{type: :tv, tmdb_id: id}, :tv), do: valid_id?(id)

  defp match_kind?(%{type: :episode, tmdb_episode_id: id}, :episode),
    do: valid_id?(id)

  defp match_kind?(_match, _kind), do: false

  defp valid_id?(id), do: is_integer(id) and id > 0

  defp same_series(%{series_tmdb_id: expected}, expected), do: :ok

  defp same_series(match, expected),
    do: {:error, {:wrong_series, expected, Map.get(match, :series_tmdb_id)}}

  defp episode_coordinates(episode, series) do
    namespace = Integer.to_string(series.tvdb_id)

    [
      coordinate(namespace, "episode_id", Integer.to_string(episode.tvdb_id)),
      coordinate(namespace, "aired", aired_code(episode))
    ]
  end

  defp coordinate(namespace, scheme, value) do
    %{
      source: "tvdb",
      scheme: scheme,
      namespace: namespace,
      canonical_value: value,
      precedence: :inferred
    }
  end

  defp aired_code(episode) do
    season = episode.season_number |> Integer.to_string() |> String.pad_leading(2, "0")
    number = episode.episode_number |> Integer.to_string() |> String.pad_leading(2, "0")
    "S#{season}E#{number}"
  end

  defp coordinate_rows(episodes, cinder_episode_ids) do
    episodes
    |> Enum.reduce_while({:ok, []}, fn episode, {:ok, rows} ->
      case Map.fetch(cinder_episode_ids, episode.tmdb_episode_id) do
        {:ok, episode_id} when is_integer(episode_id) and episode_id > 0 ->
          new_rows = Enum.map(episode.coordinates, &{episode, &1, episode_id})
          {:cont, {:ok, Enum.reverse(new_rows, rows)}}

        _missing ->
          {:halt, {:error, {:cinder_episode_not_found, episode.tmdb_episode_id}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end
end
