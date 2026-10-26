defmodule Cinder.Catalog.MediaServerSeasons do
  @moduledoc """
  The media server's TV season inventory (`Cinder.Catalog.MediaServerSeason`), keyed by the
  show's TMDB id so a season already on Plex/Jellyfin reads as available on the request page even
  for a show Cinder never added. `Cinder.Library.MediaServer.Reconciler` writes it from each
  complete read; the request page and the TV cards read it, and see only the rows of the
  configured server type (`Cinder.Settings.media_server_type/0`). Lives beside `Cinder.Catalog`
  rather than behind delegates there only because `catalog.ex` sits at the code-health line cap.
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
