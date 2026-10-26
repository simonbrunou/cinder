defmodule Cinder.Catalog.MediaServerSeasons do
  @moduledoc """
  The media server's TV season inventory (`Cinder.Catalog.MediaServerSeason`), keyed by the
  show's TMDB id so a season already on Plex/Jellyfin reads as available on the request page even
  for a show Cinder never added. `Cinder.Library.MediaServer.Reconciler` writes it from each
  complete read; the request page and the TV cards read it, and see only the rows of the
  configured server type (`Cinder.Settings.media_server_type/0`). `coverage/3` judges a season's
  count against `aired_total/2`, which counts only aired episodes while the season airs.
  Lives beside `Cinder.Catalog` rather than behind delegates there only because `catalog.ex` sits
  at the code-health line cap.
  """

  import Ecto.Query

  alias Cinder.Catalog.Events
  alias Cinder.Catalog.MediaServerSeason
  alias Cinder.Repo
  alias Cinder.Settings

  @fields [:tmdb_id, :season_number, :episode_count, :item_id]

  @doc """
  Replaces the stored inventory with a complete one. Writes and broadcasts
  `:media_server_seasons_updated` on the `"series"` topic (the one
  `Cinder.Catalog.Events.subscribe_series/0` joins) only when the set changed. The same show listed twice (two server items) keeps the
  season with more episodes.
  """
  def replace(seasons) when is_list(seasons) do
    rows =
      seasons
      |> Enum.reduce(%{}, fn season, acc ->
        row = Map.take(season, @fields)

        Map.update(
          acc,
          {row.tmdb_id, row.season_number},
          row,
          &Enum.max_by([&1, row], fn r -> r.episode_count end)
        )
      end)
      |> Map.values()

    current = Repo.all(from s in MediaServerSeason, select: map(s, ^@fields))

    if MapSet.new(current) == MapSet.new(rows), do: {:ok, :unchanged}, else: write(rows)
  end

  @doc "The media server's seasons for one show (by TMDB id), ordered by season number."
  def for_series(tmdb_id) do
    from(s in MediaServerSeason, where: s.tmdb_id == ^tmdb_id, order_by: s.season_number)
    |> written_by(Settings.media_server_type())
    |> Repo.all()
  end

  @doc "TMDB ids of every show the media server holds at least one season of."
  def series_tmdb_ids do
    from(s in MediaServerSeason, distinct: true, select: s.tmdb_id)
    |> written_by(Settings.media_server_type())
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The episode total a season's server count is judged against, from the normalized TMDB series
  (`Cinder.Catalog.TMDB` `get_series/1`).

  `{:airing, aired}` while the season airs: `next_episode_to_air` falls in it and so does
  `last_episode_to_air`, whose episode number is `aired`. `{:listed, count}` for every other
  season, a finished one or one whose premiere has not aired: TMDB's `episode_count`, which counts
  announced episodes too, or `nil` when TMDB omits it or does not list the season.
  """
  def aired_total(series, season_number) do
    case {series[:last_episode_to_air], series[:next_episode_to_air]} do
      {%{season_number: ^season_number, episode_number: aired}, %{season_number: ^season_number}}
      when is_integer(aired) and aired > 0 ->
        {:airing, aired}

      _ ->
        {:listed, episode_count(series, season_number)}
    end
  end

  @doc """
  How much of a season the media server's `count` covers, by `aired_total/2`:

    * `:up_to_date` for an airing season holding every aired episode; it has episodes to come.
    * `:complete` for any other season holding at least TMDB's `episode_count`.
    * `{:incomplete, total}` otherwise, with the total it was judged against: the aired total
      while the season airs, else `episode_count`, which can be 0, or `nil` when TMDB has none.
  """
  def coverage(series, season_number, count) do
    case aired_total(series, season_number) do
      {:airing, aired} when count >= aired -> :up_to_date
      {:listed, total} when is_integer(total) and total > 0 and count >= total -> :complete
      {_rule, total} -> {:incomplete, total}
    end
  end

  defp episode_count(series, season_number) do
    Enum.find_value(series[:seasons] || [], fn
      %{season_number: ^season_number} = season -> season[:episode_count]
      _ -> nil
    end)
  end

  # The reconciler keeps the last inventory through a failed read, so after a switch from Plex to
  # Jellyfin the rows stay Plex's until Jellyfin answers, which a wrong API key can put off for
  # good. Each row's item id starts with the type that wrote it (`Plex.list_seasons/0`'s "plex:",
  # `Jellyfin.list_seasons/0`'s "jellyfin:"), so a row counts only while that type is configured.
  # With no type to name, every row counts. `substr` is an exact prefix match, unlike LIKE.
  defp written_by(query, nil), do: query

  defp written_by(query, server) do
    prefix = "#{server}:"
    where(query, [s], fragment("substr(?, 1, ?) = ?", s.item_id, ^String.length(prefix), ^prefix))
  end

  defp write(rows) do
    Repo.transaction(fn ->
      Repo.delete_all(MediaServerSeason)
      # Chunked to stay far below SQLite's bound-parameter limit on a large library.
      rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(MediaServerSeason, &1))
    end)
    |> case do
      {:ok, _} ->
        Events.media_server_seasons_updated()
        {:ok, :replaced}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
