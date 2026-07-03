defmodule CinderWeb.LiveHelpers do
  @moduledoc """
  Small, view-agnostic helpers shared by the LiveViews. Pure functions only —
  no markup (that lives in `CinderWeb.CoreComponents`).
  """
  use Gettext, backend: CinderWeb.Gettext

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

  @doc """
  Locale-aware short date ("Jun 3" / fr "3 juin"). Both the format string and the
  month names go through gettext, so a translated locale controls word order too —
  `Calendar.strftime`'s built-in month names are English-only.
  """
  def format_date(date), do: localized_strftime(date, gettext("%b %-d"))

  @doc ~S|Locale-aware date with year ("Jun 3, 2026" / fr "3 juin 2026").|
  def format_date_year(date), do: localized_strftime(date, gettext("%b %-d, %Y"))

  defp localized_strftime(date, format),
    do: Calendar.strftime(date, format, abbreviated_month_names: &abbreviated_month_name/1)

  defp abbreviated_month_name(n) do
    Enum.at(
      [
        gettext("Jan"),
        gettext("Feb"),
        gettext("Mar"),
        gettext("Apr"),
        gettext("May"),
        gettext("Jun"),
        gettext("Jul"),
        gettext("Aug"),
        gettext("Sep"),
        gettext("Oct"),
        gettext("Nov"),
        gettext("Dec")
      ],
      n - 1
    )
  end
end
