defmodule CinderWeb.LiveHelpers do
  @moduledoc """
  Small, view-agnostic helpers shared by the LiveViews. Pure functions only —
  no markup (that lives in `CinderWeb.CoreComponents`).
  """
  use Gettext, backend: CinderWeb.Gettext

  alias Cinder.Catalog

  @doc """
  Render-time localized title for a movie/series/episode (or any map/struct carrying
  `title` + `localizations`). LiveView assigns hold the canonical struct always —
  locale only ever applies here, at render time.
  """
  def media_title(media, locale), do: Catalog.localized_title(media, locale)

  @doc "Render-time localized overview, same rule as `media_title/2`."
  def media_overview(media, locale), do: Catalog.localized_overview(media, locale)

  @doc """
  Case- and accent-folded sort key, so "Amélie" lands next to "Amelie" instead of after
  "Zorro". Codepoint order, not locale collation — "Eclair" still sorts before "Éclair"
  rather than interleaving, which is fine at household scale. Total, like
  `Cinder.Acquisition.nfd/1`: `characters_to_nfd_binary/1` returns `{:error, _, _}` on
  malformed UTF-8, and a raise here would happen inside `render/1` and take the whole
  page down. Shared by `LibraryLive` (sort) and `ActivityLive` (held-series ordering).
  """
  def fold_title(title) do
    case :unicode.characters_to_nfd_binary(title) do
      binary when is_binary(binary) -> String.downcase(binary)
      _ -> String.downcase(title)
    end
  end

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
  The status atom for a `<.status_badge kind={:movie}>` — `:verification_hold` when the movie
  is parked mid post-download verification (`verification_hold_origin` set), `:anime_hold`
  when a pre-download movie is held at search time on unsatisfiable Anime preferences
  (`anime_hold_reason` set), the movie's own pipeline `status` otherwise. Single source of
  truth for every movie-badge surface (dashboard, library, my-requests, activity, the detail
  page) so a held movie reads "Needs verification"/"Needs preferences" everywhere instead of
  the bare "Import failed"/"Searching".
  """
  def movie_badge_status(%{verification_hold_origin: origin})
      when origin in [:download, :upgrade],
      do: :verification_hold

  def movie_badge_status(%{status: status, anime_hold_reason: reason})
      when status in [:requested, :searching] and is_binary(reason),
      do: :anime_hold

  def movie_badge_status(movie), do: movie.status

  @doc """
  The lifecycle atom for a `<.status_badge kind={:grab}>` from a grab row: a mapping or
  verification hold when flagged, else `:downloading` (no delivered content yet) or
  `:downloaded` (content in hand, waiting to import). Shared by `/activity` and the beacon.
  """
  def grab_state(%{mapping_status: :needs_mapping}), do: :needs_mapping
  def grab_state(%{mapping_status: :verification_blocked}), do: :verification_blocked
  def grab_state(%{content_path: nil}), do: :downloading
  def grab_state(_), do: :downloaded

  @doc """
  Whether a failed `Requests.create_request/2` changeset is the benign duplicate-pending
  case (the `requests_pending_unique` index; Ecto tags it `constraint: :unique`). Any
  other changeset failure is a real error, not a reassuring "already requested" toast.
  """
  def duplicate_request?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  @doc ~S"""
  The render-time localized display title for a request row: "Title: Season N" for a
  season request, the localized title otherwise. A request row carries its own
  `localizations` copy, so this goes through `Catalog.localized_title/2` like any
  other media.
  """
  def request_title(%{target_type: "season"} = r, locale),
    do:
      gettext("%{title}: Season %{number}",
        title: Catalog.localized_title(r, locale),
        number: r.season_number
      )

  def request_title(r, locale), do: Catalog.localized_title(r, locale)

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
