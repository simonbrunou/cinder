defmodule CinderWeb.LiveHelpers do
  @moduledoc """
  Small, view-agnostic helpers shared by the LiveViews. Pure functions only —
  no markup (that lives in `CinderWeb.CoreComponents`).
  """
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [language_label: 1]

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
  The lifecycle atom for a `<.status_badge kind={:grab}>` from a grab row: the badge for the
  grab's `Catalog.grab_hold/1` class (a residual-files hold wears the `:needs_mapping` badge),
  else `:downloading` (no delivered content yet) or `:downloaded` (content in hand, waiting to
  import). The hold classification itself lives in the Catalog — this only picks badges.
  Shared by `/activity` and the beacon.
  """
  def grab_state(%{content_path: nil} = grab) do
    case Catalog.grab_hold(grab) do
      hold when hold in [:needs_mapping, :verification_blocked] -> hold
      _residual_or_none -> :downloading
    end
  end

  def grab_state(grab) do
    case Catalog.grab_hold(grab) do
      nil -> :downloaded
      :residual_files -> :needs_mapping
      hold -> hold
    end
  end

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
  A plain-English line under an in-flight/parked movie card: what phase it's in (with the
  search attempt count) or why it's stuck and what to do. Complements the badge, which
  names the state. Shared by `/activity` (every parked movie) and `/my-requests` (a
  requester's own movie rows).
  """
  def pipeline_hint(%{status: :searching, search_attempts: n}),
    do: gettext("Searching indexers (attempt %{n})", n: n + 1)

  def pipeline_hint(%{status: :no_match}),
    do: gettext("No release matched your size/quality rules yet. Open it to retry or adjust.")

  def pipeline_hint(%{status: :search_failed}),
    do: gettext("The indexer couldn't be reached after repeated tries. Open it to retry.")

  def pipeline_hint(%{status: :import_failed}),
    do: gettext("The download finished but couldn't be imported. Open it to retry.")

  def pipeline_hint(_movie), do: nil

  @doc """
  Plain-English hold reason: which safety check failed, plus the offending file names or
  episode ids — reused straight off the persisted `mapping_issue` (no separate display
  model). Grab-specific, so only `/activity` (the only surface rendering individual TV
  grabs) calls this today.
  """
  def mapping_reason(%{"reason" => "unresolved_file", "relative_paths" => paths}),
    do: gettext("Couldn't match to an episode: %{paths}", paths: path_list(paths))

  def mapping_reason(%{"reason" => "outside_authoritative_set", "relative_paths" => paths}),
    do: gettext("Matched an episode outside this release: %{paths}", paths: path_list(paths))

  def mapping_reason(%{"reason" => "duplicate_episode_assignment", "relative_paths" => paths}),
    do: gettext("More than one file matched the same episode: %{paths}", paths: path_list(paths))

  def mapping_reason(%{
        "reason" => "missing_episode_assignment",
        "candidate_episode_ids" => episode_ids
      }),
      do: gettext("No file found for episode id(s): %{ids}", ids: id_list(episode_ids))

  def mapping_reason(%{
        "reason" => "reserved_set_divergence",
        "candidate_episode_ids" => episode_ids
      }),
      do:
        gettext(
          "The library's episodes no longer match what this grab reserved; affected episode id(s): %{ids}",
          ids: id_list(episode_ids)
        )

  def mapping_reason(_issue), do: gettext("This release needs manual attention.")

  defp path_list(paths) when is_list(paths) and paths != [], do: Enum.join(paths, ", ")
  defp path_list(_paths), do: gettext("unknown file")

  defp id_list(ids) when is_list(ids) and ids != [], do: Enum.join(ids, ", ")
  defp id_list(_ids), do: gettext("unknown")

  @doc """
  Plain-English search-time hold reason (`anime_hold_reason`, the AnimePreferences.resolve
  error) naming the fix — cleared automatically by the next sweep once preferences resolve.
  Shared by `/activity` (movies + held series) and `/my-requests` (a requester's own held
  movie rows).
  """
  def anime_hold_reason("original_language_required"),
    do:
      gettext(
        "Dual audio needs this title's original language, which is unknown: on its detail page, choose an Audio pick other than \"%{dual}\", or fix the title's original-language metadata.",
        dual: language_label("dual")
      )

  def anime_hold_reason("subtitle_language_required"),
    do:
      gettext(
        "Requiring embedded subtitles needs subtitle languages: configure them in Settings."
      )

  def anime_hold_reason(_reason),
    do: gettext("The Anime release preferences can't be satisfied for this title.")

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

  @doc """
  A localized "time ago" fragment for a past timestamp ("just now" / "3 minutes ago" /
  "2 days ago"). Accepts a `NaiveDateTime` (Ecto `timestamps()` are UTC-naive) or a `DateTime`;
  `now` is injectable for deterministic tests. Coarse minute/hour/day buckets — plenty for a
  "requested N ago" line at household scale. `ngettext` gives each locale its own plural rule,
  and a future timestamp (clock skew) clamps to "just now" rather than reading "-1 minutes ago".
  """
  def relative_time(datetime, now \\ DateTime.utc_now())

  def relative_time(%NaiveDateTime{} = naive, now),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> relative_time(now)

  def relative_time(%DateTime{} = datetime, now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      seconds < 60 ->
        gettext("just now")

      seconds < 3_600 ->
        minutes = div(seconds, 60)
        ngettext("%{count} minute ago", "%{count} minutes ago", minutes)

      seconds < 86_400 ->
        hours = div(seconds, 3_600)
        ngettext("%{count} hour ago", "%{count} hours ago", hours)

      true ->
        days = div(seconds, 86_400)
        ngettext("%{count} day ago", "%{count} days ago", days)
    end
  end

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

  @doc "Plain-English standard-TV residual hold reason."
  def grab_file_hold_reason(count) do
    ngettext(
      "%{count} unmatched video was kept in the download source for review.",
      "%{count} unmatched videos were kept in the download source for review.",
      count
    )
  end

  @doc """
  True when a settings-form payload is shaped the way a real submit is.

  `Cinder.Settings.save_form/1` reaches into the payload's **values** — `String.trim/1` in both
  `invalid_band_values/1` and `plan_config/3`, `String.split/2` in `invalid_import_roots/1` — each
  of which raises on a non-binary, past the point where the `handle_event` clause has matched and
  so past the module's catch-all. The settings and setup forms are flat, submit-only and carry no
  multi-value input, so every legitimate value is a string.

  Note this says nothing about *which* keys are present: an all-binary payload that merely omits a
  toggle still reads as unchecked to `plan/1`. This is only about not crashing.
  """
  def settings_params?(params) when is_map(params),
    do: Enum.all?(params, fn {_key, value} -> is_binary(value) end)

  def settings_params?(_params), do: false

  @doc "Confirmation caveat for discarding every unresolved file of one download."
  def discard_all_caveat(count) do
    ngettext(
      "Discard %{count} unmatched video? It is not kept and cannot be recovered here.",
      "Discard all %{count} unmatched videos? They are not kept and cannot be recovered here.",
      count
    )
  end
end
