defmodule CinderWeb.LiveHelpers do
  @moduledoc """
  Small, view-agnostic helpers shared by the LiveViews. Pure functions only —
  no markup (that lives in `CinderWeb.CoreComponents`).
  """

  @doc """
  Finds an item in `collection` whose `id` stringifies to `id` (a client-supplied,
  string `phx-value`). The string compare is forged-id-safe: a non-numeric value
  resolves to `nil` rather than reaching `String.to_integer/1` or `Repo.get`.
  """
  def find_by_id(collection, id), do: Enum.find(collection, &(to_string(&1.id) == id))

  @doc """
  Replaces `item` in `list` if an entry with the same `id` exists, else prepends it.
  Used to keep a live list in sync with `{:*_updated}` / `{:*_created}` broadcasts.
  """
  def upsert_by_id(list, item) do
    if Enum.any?(list, &(&1.id == item.id)),
      do: Enum.map(list, &if(&1.id == item.id, do: item, else: &1)),
      else: [item | list]
  end

  @doc """
  Reduces request rows (newest-first) to a `key => status` map, keeping the first
  (newest) status seen per key. `key_fun` picks the key (e.g. `& &1.target_id`).
  """
  def latest_status_by(items, key_fun) do
    Enum.reduce(items, %{}, fn r, acc -> Map.put_new(acc, key_fun.(r), r.status) end)
  end
end
