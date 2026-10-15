defmodule Cinder.Catalog.MediaServerSeasons do
  @moduledoc """
  The media server's TV season inventory (`Cinder.Catalog.MediaServerSeason`), keyed by the
  show's TMDB id so a season already on Plex/Jellyfin reads as available on the request page even
  for a show Cinder never added. `Cinder.Library.MediaServer.Reconciler` writes it from each
  complete read; the request page and the TV cards read it. Lives beside `Cinder.Catalog` rather
  than behind delegates there only because `catalog.ex` sits at the code-health line cap.
  """

  import Ecto.Query

  alias Cinder.Catalog.MediaServerSeason
  alias Cinder.Repo

  @fields [:tmdb_id, :season_number, :episode_count, :item_id]

  @doc """
  Replaces the stored inventory with a complete one. Writes and broadcasts
  `:media_server_seasons_updated` on the `"series"` topic (the one `Catalog.subscribe_series/0`
  joins) only when the set changed. The same show listed twice (two server items) keeps the
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
    Repo.all(from s in MediaServerSeason, where: s.tmdb_id == ^tmdb_id, order_by: s.season_number)
  end

  @doc "TMDB ids of every show the media server holds at least one season of."
  def series_tmdb_ids do
    Repo.all(from s in MediaServerSeason, distinct: true, select: s.tmdb_id) |> MapSet.new()
  end

  defp write(rows) do
    Repo.transaction(fn ->
      Repo.delete_all(MediaServerSeason)
      # Chunked to stay far below SQLite's bound-parameter limit on a large library.
      rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(MediaServerSeason, &1))
    end)
    |> case do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Cinder.PubSub, "series", :media_server_seasons_updated)
        {:ok, :replaced}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
