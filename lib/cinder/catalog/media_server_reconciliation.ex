defmodule Cinder.Catalog.MediaServerReconciliation do
  @moduledoc false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Repo

  def reconcile(kind, items) when kind in [:movies, :tv] and is_list(items) do
    ids =
      Enum.reduce(items, %{}, fn
        %{tmdb_id: tmdb_id, id: item_id}, acc
        when is_integer(tmdb_id) and tmdb_id > 0 and is_binary(item_id) and item_id != "" ->
          Map.put_new(acc, tmdb_id, item_id)

        _item, acc ->
          acc
      end)

    schema = if kind == :movies, do: Movie, else: Series

    case Repo.transaction(fn -> reconcile_rows(schema, ids) end) do
      {:ok, updated} ->
        Enum.each(updated, &broadcast(kind, &1))
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_rows(schema, ids) do
    schema
    |> Repo.all()
    |> Enum.reduce([], &reconcile_row(&1, &2, schema, ids))
    |> Enum.reverse()
  end

  defp reconcile_row(row, updated, schema, ids) do
    item_id = Map.get(ids, row.tmdb_id)

    if row.media_server_item_id == item_id do
      updated
    else
      case Repo.update(schema.media_server_changeset(row, item_id)) do
        {:ok, row} -> [row | updated]
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp broadcast(:movies, movie), do: Catalog.broadcast({:movie_updated, movie})
  defp broadcast(:tv, series), do: Catalog.broadcast_series(series.id)
end
