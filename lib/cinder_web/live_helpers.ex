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
  Whether a failed `Requests.create_request/2` changeset is the benign duplicate-pending
  case (the `requests_pending_unique` index; Ecto tags it `constraint: :unique`). Any
  other changeset failure is a real error, not a reassuring "already requested" toast.
  """
  def duplicate_request?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  @doc ~S(The display title for a request row: "Title: Season N" for a season request, the bare title otherwise.)
  def request_title(%{target_type: "season"} = r),
    do: gettext("%{title}: Season %{number}", title: r.title, number: r.season_number)

  def request_title(r), do: r.title

  @doc """
  Locale-aware short date ("Jun 3" / fr "3 juin"). Both the format string and the
  month names go through gettext, so a translated locale controls word order too —
  `Calendar.strftime`'s built-in month names are English-only.
  """
  def format_date(date), do: localized_strftime(date, gettext("%b %-d"), "%b %-d")

  @doc ~S|Locale-aware date with year ("Jun 3, 2026" / fr "3 juin 2026").|
  def format_date_year(date), do: localized_strftime(date, gettext("%b %-d, %Y"), "%b %-d, %Y")

  @doc ~S|A file size for display ("8.4 GB" / "720 MB"). `nil`/non-positive → `nil` (caller hides the label). ponytail: GB/MB only, one decimal — plenty for a household file-size chip.|
  def humanize_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def humanize_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def humanize_bytes(bytes) when is_integer(bytes) and bytes > 0, do: "#{bytes} B"
  def humanize_bytes(_), do: nil

  @doc ~S|A one-decimal rating string ("8.4") for a TMDB vote average (an Ecto :float). Non-floats fall through to to_string/1 as a defensive fallback.|
  def rating(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  def rating(v), do: to_string(v)

  # The translated format is translator-controlled data executed as strftime syntax;
  # a bad .po directive must degrade to the English msgid format, not crash-loop
  # every view render for that locale. (The test suite pins known locales' catalogs,
  # but a runtime guard is what actually protects a live instance.)
  defp localized_strftime(date, format, fallback) do
    Calendar.strftime(date, format, abbreviated_month_names: &abbreviated_month_name/1)
  rescue
    _ -> Calendar.strftime(date, fallback, abbreviated_month_names: &abbreviated_month_name/1)
  end

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
