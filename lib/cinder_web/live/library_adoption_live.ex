defmodule CinderWeb.LibraryAdoptionLive do
  @moduledoc """
  Admin workflow for scanning configured library roots and adopting confirmed
  movie and series matches without blocking the LiveView process.
  """

  use CinderWeb, :live_view

  alias Cinder.Catalog.Episode
  alias Cinder.Library.Adoption
  alias Cinder.Settings

  # Migration buckets can hold thousands of rows; render a bounded page per bucket and keep the
  # selection/decision state server-side (keyed by stable candidate id), independent of what the
  # current window streams.
  @page_size 50
  @empty_buckets %{ready: [], needs_decision: [], blocked: [], already_managed: []}
  @first_pages %{ready: 1, needs_decision: 1, blocked: 1, already_managed: 1}
  # Compile-time source-key set for the `scan_migration` guard below. `Registry.migration_sources/0`
  # is a compile-time literal, so — unlike a value read from `socket.assigns` at runtime, which a
  # guard can never reference — this can be, and is, checked with a real guard clause: a new
  # registry entry needs no second hand-edit here.
  @migration_source_keys Settings.migration_sources() |> Enum.map(& &1.key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       candidates: [],
       counts: %{auto_matched: 0, ambiguous: 0, unmatched: 0, already_managed: 0},
       form: to_form(%{}, as: :adoption),
       mode: :filesystem,
       migration_source: nil,
       migration_sources: Settings.migration_sources(),
       migration_buckets: @empty_buckets,
       migration_deferred: %{count: 0, links: %{}},
       selected_ready: MapSet.new(),
       decisions: %{},
       pages: @first_pages,
       undecided_skipped: 0,
       scanned?: false,
       scanning?: false,
       adopting?: false,
       adoption_failures: [],
       readarr_progress: nil,
       readarr_candidates: [],
       readarr_seen: MapSet.new(),
       cancelling?: false
     )
     |> stream_configure(:auto_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(:ambiguous_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(:unmatched_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(:managed_candidates, dom_id: &"adoption-candidate-#{&1.id}")
     |> stream_configure(
       :migration_series_counts,
       dom_id: &"migration-series-#{&1.provider_id}"
     )
     |> stream(:auto_candidates, [])
     |> stream(:ambiguous_candidates, [])
     |> stream(:unmatched_candidates, [])
     |> stream(:managed_candidates, [])
     |> stream(:migration_series_counts, [])}
  end

  @impl true
  def handle_event("scan", _params, %{assigns: %{scanning?: false, adopting?: false}} = socket),
    do:
      {:noreply,
       socket
       |> assign(adoption_failures: [], mode: :filesystem, migration_source: nil)
       |> start_scan()}

  def handle_event(
        "scan_migration",
        %{"source" => source},
        %{assigns: %{scanning?: false, adopting?: false}} = socket
      )
      when source in @migration_source_keys do
    source = String.to_existing_atom(source)

    {:noreply,
     socket
     |> assign(
       adoption_failures: [],
       mode: {:migration, source},
       migration_source: source
     )
     |> start_scan()}
  end

  def handle_event(
        "adopt",
        %{"adoption" => params},
        %{assigns: %{adopting?: false, mode: :filesystem}} = socket
      )
      when is_map(params) do
    confirmed = Adoption.confirmed_candidates(socket.assigns.candidates, params)

    case confirmed do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one match to adopt."))}

      candidates ->
        {:noreply,
         socket
         |> assign(adopting?: true, adoption_failures: [])
         |> start_async(:adopt, fn -> Adoption.adopt(candidates) end)}
    end
  end

  def handle_event("toggle_ready", %{"id" => raw}, socket) do
    with id when not is_nil(id) <- parse_id(raw),
         %{} = candidate <- Enum.find(current_page(socket, :ready), &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(selected_ready: toggle_member(socket.assigns.selected_ready, id))
       |> stream_insert(:auto_candidates, candidate)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_all_ready", _params, socket) do
    ready = socket.assigns.migration_buckets.ready

    {:noreply,
     socket
     |> assign(selected_ready: MapSet.new(ready, & &1.id))
     |> restream(:ready)}
  end

  def handle_event("deselect_all_ready", _params, socket) do
    {:noreply, socket |> assign(selected_ready: MapSet.new()) |> restream(:ready)}
  end

  def handle_event("set_decision", %{"id" => raw, "choice" => choice}, socket)
      when choice in ["fold", "part", "preferred", "all_formats"] do
    with id when not is_nil(id) <- parse_id(raw),
         %{} = candidate <- Enum.find(current_page(socket, :needs_decision), &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(decisions: Map.put(socket.assigns.decisions, id, choice))
       |> stream_insert(:ambiguous_candidates, candidate)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Bulk apply is an explicit operator action: it only fills items that have no decision yet, so a
  # per-candidate choice set before or after survives untouched.
  def handle_event("apply_all", %{"choice" => choice}, socket)
      when choice in ["fold", "part", "preferred", "all_formats"] do
    decisions =
      Enum.reduce(socket.assigns.migration_buckets.needs_decision, socket.assigns.decisions, fn
        candidate, acc -> Map.put_new(acc, candidate.id, choice)
      end)

    {:noreply, socket |> assign(decisions: decisions) |> restream(:needs_decision)}
  end

  def handle_event("page", %{"bucket" => raw, "dir" => dir}, socket)
      when dir in ["prev", "next"] do
    case bucket_key(raw) do
      nil ->
        {:noreply, socket}

      bucket ->
        total = total_pages(length(Map.fetch!(socket.assigns.migration_buckets, bucket)))
        step = if dir == "next", do: 1, else: -1
        page = clamp(Map.fetch!(socket.assigns.pages, bucket) + step, 1, total)

        {:noreply,
         socket
         |> assign(pages: Map.put(socket.assigns.pages, bucket, page))
         |> restream(bucket)}
    end
  end

  def handle_event(
        "adopt_migration",
        _params,
        %{assigns: %{adopting?: false, mode: {:migration, source}} = assigns} = socket
      ) do
    commands =
      Adoption.confirmed_migration_commands(
        assigns.migration_buckets,
        assigns.selected_ready,
        assigns.decisions
      )

    case commands do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one match to adopt."))}

      commands ->
        undecided =
          Adoption.undecided_count(assigns.migration_buckets.needs_decision, assigns.decisions)

        {:noreply,
         socket
         |> assign(adopting?: true, adoption_failures: [], undecided_skipped: undecided)
         |> start_async(:adopt, fn -> Adoption.adopt_migration(source, commands) end)}
    end
  end

  def handle_event(
        "cancel_scan",
        _params,
        %{assigns: %{scanning?: true, mode: {:migration, :readarr}}} = socket
      ),
      do: {:noreply, assign(socket, cancelling?: true)}

  # Client-controlled events and malformed params are ignored rather than crashing the page.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:scan, {:ok, candidates}, socket) when is_list(candidates),
    do: {:noreply, put_candidates(socket, candidates)}

  # `:readarr` auto-advances through `Readarr.plan/2`'s bounded batches (B6c) — each batch's
  # candidates are merged into `@readarr_candidates`, and `@readarr_seen` (the excluded set fed
  # back into the next `preview_migration/2` call) grows so the next batch never re-pays or
  # re-emits a work this session already classified. Stops on `preview.remaining == 0` or an
  # operator Cancel (`@cancelling?`), renumbering the merged candidates' ids (batch-local ids
  # collide across batches) before handing off to `put_migration_preview/2`.
  def handle_async(
        :scan,
        {:ok, {:ok, preview}},
        %{assigns: %{mode: {:migration, :readarr}}} = socket
      ) do
    merged = socket.assigns.readarr_candidates ++ preview.candidates

    seen =
      Enum.reduce(
        preview.candidates,
        socket.assigns.readarr_seen,
        &MapSet.put(&2, &1.provider_id)
      )

    progress = %{resolved: length(merged), remaining: preview.remaining}

    socket =
      assign(socket, readarr_candidates: merged, readarr_seen: seen, readarr_progress: progress)

    if socket.assigns.cancelling? or preview.remaining == 0 do
      {:noreply,
       socket
       |> assign(scanning?: false, cancelling?: false)
       |> put_migration_preview(%{preview | candidates: renumber_candidates(merged)})}
    else
      {:noreply,
       start_async(socket, :scan, fn -> Adoption.preview_migration(:readarr, exclude: seen) end)}
    end
  end

  def handle_async(:scan, {:ok, {:ok, preview}}, socket) when is_map(preview),
    do: {:noreply, put_migration_preview(socket, preview)}

  def handle_async(:scan, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false)
     |> put_flash(
       :error,
       gettext("Migration source scan failed. Check its settings and try again.")
     )}
  end

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false)
     |> put_flash(:error, gettext("Library scan failed. Please try again."))}
  end

  def handle_async(:adopt, {:ok, summary}, socket) do
    {:noreply,
     socket
     |> assign(adopting?: false, adoption_failures: summary.failures, undecided_skipped: 0)
     |> put_flash(:info, adopt_message(summary, socket.assigns.undecided_skipped))
     |> refresh_after_adopt(summary)}
  end

  def handle_async(:adopt, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(adopting?: false)
     |> put_flash(:error, gettext("Adoption failed. Please try again."))}
  end

  # Admin sockets are subscribed to the "requests" topic (nav-badge on_mount); ignore those
  # broadcasts here — the on_mount hook already re-renders the badge.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp start_scan(%{assigns: %{mode: :filesystem}} = socket) do
    socket
    |> reset_scan_results()
    |> assign(scanning?: true)
    |> start_async(:scan, &Adoption.scan/0)
  end

  defp start_scan(%{assigns: %{mode: {:migration, source}}} = socket) do
    socket
    |> reset_scan_results()
    |> assign(scanning?: true)
    |> start_async(:scan, fn -> Adoption.preview_migration(source) end)
  end

  # The mode flips at click but results arrive async: clear the previous scan's buckets and
  # streams BEFORE launching, so the summary/forms never render counts produced by a different
  # mode than they're labeled with (and a failed scan leaves an empty state, not a stale one).
  defp reset_scan_results(socket) do
    socket
    |> assign(
      candidates: [],
      counts: %{auto_matched: 0, ambiguous: 0, unmatched: 0, already_managed: 0},
      form: to_form(%{}, as: :adoption),
      migration_buckets: @empty_buckets,
      migration_deferred: %{count: 0, links: %{}},
      selected_ready: MapSet.new(),
      decisions: %{},
      pages: @first_pages,
      undecided_skipped: 0,
      scanned?: false,
      readarr_progress: nil,
      readarr_candidates: [],
      readarr_seen: MapSet.new(),
      cancelling?: false
    )
    |> stream(:auto_candidates, [], reset: true)
    |> stream(:ambiguous_candidates, [], reset: true)
    |> stream(:unmatched_candidates, [], reset: true)
    |> stream(:managed_candidates, [], reset: true)
    |> stream(:migration_series_counts, [], reset: true)
  end

  defp put_candidates(socket, candidates) do
    auto = Enum.filter(candidates, &(&1.status == :auto_matched))
    ambiguous = Enum.filter(candidates, &(&1.status == :ambiguous))
    unmatched = Enum.filter(candidates, &(&1.status == :unmatched))

    socket
    |> assign(
      candidates: candidates,
      counts: %{
        auto_matched: length(auto),
        ambiguous: length(ambiguous),
        unmatched: length(unmatched),
        already_managed: 0
      },
      form: to_form(%{}, as: :adoption),
      scanned?: true,
      scanning?: false
    )
    |> stream(:auto_candidates, auto, reset: true)
    |> stream(:ambiguous_candidates, ambiguous, reset: true)
    |> stream(:unmatched_candidates, unmatched, reset: true)
    |> stream(:managed_candidates, [], reset: true)
    |> stream(:migration_series_counts, [], reset: true)
  end

  defp put_migration_preview(socket, preview) do
    ready = Enum.filter(preview.candidates, &(&1.status == :ready))
    decision = Enum.filter(preview.candidates, &(&1.status == :needs_decision))
    blocked = Enum.filter(preview.candidates, &(&1.status == :blocked))
    managed = Enum.filter(preview.candidates, &(&1.status == :already_managed))

    buckets = %{
      ready: ready,
      needs_decision: decision,
      blocked: blocked,
      already_managed: managed
    }

    socket
    |> assign(
      candidates: preview.candidates,
      migration_buckets: buckets,
      migration_deferred: migration_deferred(preview),
      # Ready items are pre-selected (the previous default); the operator prunes with the header
      # controls. Decisions start empty — there is never a default fold/part.
      selected_ready: MapSet.new(ready, & &1.id),
      decisions: %{},
      pages: @first_pages,
      undecided_skipped: 0,
      # Derived from THIS call's own filtered lists, not `preview.counts` — identical for a
      # single-shot (:radarr/:sonarr) preview by construction, and correct for a `:readarr`
      # batch-accumulated one, whose merged `candidates` no longer match any single batch's own
      # `preview.counts` (each batch computes counts over only its own slice).
      counts: %{
        auto_matched: length(ready),
        ambiguous: length(decision),
        unmatched: length(blocked),
        already_managed: length(managed)
      },
      form: to_form(%{}, as: :adoption),
      migration_source: preview.source,
      scanned?: true,
      scanning?: false
    )
    |> stream(:auto_candidates, page_slice(ready, 1), reset: true)
    |> stream(:ambiguous_candidates, page_slice(decision, 1), reset: true)
    |> stream(:unmatched_candidates, page_slice(blocked, 1), reset: true)
    |> stream(:managed_candidates, page_slice(managed, 1), reset: true)
    |> stream(:migration_series_counts, preview.series_counts, reset: true)
  end

  # `:readarr`-only fields (`preview.deferred_bibliography_count`/`_authors`, added B6c on top of
  # B6b's `Readarr.summary/2`); absent from a :radarr/:sonarr preview, defaulted away harmlessly.
  # `links` resolves each deferred author id to a Cinder work id worth linking to — one already
  # classified in THIS same preview, credited to that exact author, with a known catalog
  # `work_id` — so `/books/:id` (where B5b's "Set author policy" control lives) is only ever
  # offered when it genuinely resolves to that author's own page. An author with no such
  # candidate in this preview (nothing of theirs was ever imported before, or not yet resolved
  # this session) gets no link — never a guessed one.
  defp migration_deferred(preview) do
    count = Map.get(preview, :deferred_bibliography_count, 0)
    author_ids = Map.get(preview, :deferred_bibliography_authors, [])

    by_author =
      preview.candidates
      |> Enum.filter(&(Map.get(&1, :kind) == :book and not is_nil(Map.get(&1, :work_id))))
      |> Map.new(&{&1.author_id, &1.work_id})

    links =
      for author_id <- author_ids, work_id = Map.get(by_author, author_id), into: %{} do
        {author_id, work_id}
      end

    %{count: count, links: links}
  end

  defp current_page(socket, bucket) do
    page_slice(
      Map.fetch!(socket.assigns.migration_buckets, bucket),
      Map.fetch!(socket.assigns.pages, bucket)
    )
  end

  defp restream(socket, bucket) do
    list = Map.fetch!(socket.assigns.migration_buckets, bucket)
    page = Map.fetch!(socket.assigns.pages, bucket)
    stream(socket, stream_for(bucket), page_slice(list, page), reset: true)
  end

  defp page_slice(list, page), do: Enum.slice(list, (page - 1) * @page_size, @page_size)

  # Merged across `:readarr` batches (B6c), each batch's `preview.candidates` carry ids assigned
  # independently within that batch alone (`MigrationAdoption.preview_result/4`'s own
  # `Enum.with_index(1)`) — colliding once merged. Re-derives stable, unique ids over the FULL
  # merged list the same way, so selection/decision state and stream dom ids never collide.
  defp renumber_candidates(candidates) do
    candidates
    |> Enum.sort_by(& &1.key)
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, id} -> Map.put(candidate, :id, id) end)
  end

  defp total_pages(count) when count <= 0, do: 1
  defp total_pages(count), do: ceil(count / @page_size)

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp bucket_key("ready"), do: :ready
  defp bucket_key("needs_decision"), do: :needs_decision
  defp bucket_key("blocked"), do: :blocked
  defp bucket_key("already_managed"), do: :already_managed
  defp bucket_key(_other), do: nil

  defp stream_for(:ready), do: :auto_candidates
  defp stream_for(:needs_decision), do: :ambiguous_candidates
  defp stream_for(:blocked), do: :unmatched_candidates
  defp stream_for(:already_managed), do: :managed_candidates

  defp adopt_message(summary, undecided) do
    base =
      gettext("Adopted %{adopted}; skipped %{skipped}.",
        adopted: summary.adopted,
        skipped: summary.skipped
      )

    if undecided > 0 do
      base <>
        " " <>
        ngettext(
          "%{count} item was skipped because it still needed a decision.",
          "%{count} items were skipped because they still needed a decision.",
          undecided
        )
    else
      base
    end
  end

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp title(candidate) do
    if candidate.year,
      do: "#{candidate.title} (#{candidate.year})",
      else: candidate.title
  end

  defp match_title(match) do
    if match.year, do: "#{match.title} (#{match.year})", else: match.title
  end

  defp kind_label(:movie), do: gettext("Movie")
  defp kind_label(:series), do: gettext("Series")

  defp file_label(%{season_number: season, episode_numbers: episodes})
       when is_integer(season) and episodes != [],
       do: Episode.codes_label(season, episodes)

  defp file_label(_file), do: gettext("No episode number")

  defp part_label(part) do
    code = Episode.code(part.season_number, part.episode_number)
    if part.title in [nil, ""], do: code, else: "#{code} · #{part.title}"
  end

  defp reason_text(:stale_candidate),
    do: gettext("This item changed since the scan; run the preview again.")

  defp reason_text({:episode_not_found, _missing}),
    do: gettext("The parsed episode does not exist in TMDB.")

  defp reason_text({:duplicate_episode_claim, _keys}),
    do: gettext("Several files claim this episode; resolve the duplicates on disk first.")

  defp reason_text(:episode_number_not_found),
    do: gettext("No SxxEyy episode number was found.")

  defp reason_text(:no_matched_episodes),
    do: gettext("None of the parsed episodes exist in TMDB.")

  defp reason_text({:scan_failed, _reason}),
    do: gettext("This library root could not be scanned.")

  defp reason_text({:tmdb_search_failed, _reason}),
    do: gettext("TMDB search failed.")

  defp reason_text({:tmdb_details_failed, _reason}),
    do: gettext("TMDB episode details could not be loaded.")

  defp reason_text(:file_missing), do: gettext("The source did not provide a usable file path.")
  defp reason_text(:unlinked_file), do: gettext("The source file is not linked to a title.")
  defp reason_text(:path_conflict), do: gettext("This path is already managed by another title.")

  defp reason_text(:identity_conflict),
    do: gettext("This title already manages a different file.")

  defp reason_text(:series_unresolved), do: gettext("The source series could not be resolved.")
  defp reason_text(:no_match), do: gettext("The provider identity returned no TMDB match.")

  defp reason_text(:multiple_matches),
    do: gettext("The provider identity returned several TMDB matches.")

  defp reason_text({:wrong_series, _expected, _actual}),
    do: gettext("The episode identity belongs to a different series.")

  defp reason_text(:authoritative_primary_unresolved),
    do: gettext("Cinder could not prove which file is the authoritative primary.")

  defp reason_text(:complex_n_to_one),
    do: gettext("This file split is too complex to adopt safely.")

  defp reason_text(:catalog_episode_missing),
    do: gettext("The matching episode is missing from Cinder's catalog.")

  defp reason_text({:unresolved_identity, :providers_unavailable}),
    do: gettext("Every metadata provider was unavailable.")

  defp reason_text({:unresolved_identity, _reason}),
    do: gettext("No reliable metadata match was found for this work.")

  defp reason_text(:unsupported_format),
    do: gettext("None of this work's files are in an accepted e-book format.")

  defp reason_text(:target_held),
    do: gettext("This title is held and needs an operator decision first.")

  defp reason_text(:outside_library_root),
    do: gettext("This file is outside the configured books library root.")

  defp reason_text(_reason), do: gettext("No safe match was found.")

  defp adoption_failure_label(%{episode_code: code, path: path})
       when is_binary(code) and is_binary(path),
       do: "#{code} · #{Path.basename(path)}"

  defp adoption_failure_label(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp adoption_failure_label(_failure), do: gettext("Unknown file")

  defp adoption_failure_text(%{reason: :primary_file_missing}),
    do: gettext("The episode has no primary file to attach this part to.")

  defp adoption_failure_text(%{reason: :already_has_file}),
    do: gettext("The episode already points to another file.")

  defp adoption_failure_text(%{reason: :episode_not_found}),
    do: gettext("The episode changed while adoption was running.")

  defp adoption_failure_text(_failure), do: gettext("The catalog rejected this file.")

  defp source_label(:radarr), do: gettext("Radarr")
  defp source_label(:sonarr), do: gettext("Sonarr")
  defp source_label(:readarr), do: gettext("Readarr")

  defp migration_title(candidate) do
    case Map.get(candidate, :year) do
      year when is_integer(year) -> "#{candidate.title} (#{year})"
      _year -> candidate.title
    end
  end

  defp migration_path(candidate) do
    Map.get(candidate, :path) ||
      get_in(candidate, [:primary_file, :path])
  end

  defp file_name(path) when is_binary(path), do: Path.basename(path)
  defp file_name(_path), do: gettext("No file")

  attr :bucket, :atom, required: true
  attr :page, :integer, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true

  defp migration_pager(assigns) do
    assigns = assign(assigns, :total, total_pages(assigns.count))

    ~H"""
    <nav
      :if={@total > 1}
      class="mt-3 flex items-center justify-center gap-3"
      aria-label={gettext("%{label} pages", label: @label)}
    >
      <.button
        type="button"
        variant="neutral"
        size="sm"
        phx-click="page"
        phx-value-bucket={@bucket}
        phx-value-dir="prev"
        disabled={@page <= 1}
        aria-label={gettext("Previous page of %{label}", label: @label)}
      >
        {gettext("Previous")}
      </.button>
      <span class="text-sm text-base-content/70">
        {gettext("Page %{page} of %{total}", page: @page, total: @total)}
      </span>
      <.button
        type="button"
        variant="neutral"
        size="sm"
        phx-click="page"
        phx-value-bucket={@bucket}
        phx-value-dir="next"
        disabled={@page >= @total}
        aria-label={gettext("Next page of %{label}", label: @label)}
      >
        {gettext("Next")}
      </.button>
    </nav>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.header>
        {gettext("Adopt existing library")}
        <:subtitle>
          {gettext(
            "Scan your movie and TV roots, confirm matches, and bring existing files under Cinder's management."
          )}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/library"} class="btn btn-ghost">{gettext("Back to library")}</.link>
        </:actions>
      </.header>

      <div class="mb-6 flex flex-wrap items-center gap-3">
        <.button
          id="scan-library"
          type="button"
          phx-click="scan"
          disabled={@scanning? or @adopting?}
        >
          {if @scanning?, do: gettext("Scanning…"), else: gettext("Scan")}
        </.button>
        <.button
          :for={source <- @migration_sources}
          id={"scan-#{source.key}"}
          type="button"
          variant="neutral"
          phx-click="scan_migration"
          phx-value-source={source.key}
          disabled={@scanning? or @adopting?}
        >
          {gettext("Preview %{name}", name: source.name)}
        </.button>
        <.button
          :if={match?({:migration, :readarr}, @mode) and @scanning?}
          id="cancel-readarr-scan"
          type="button"
          variant="neutral"
          phx-click="cancel_scan"
          disabled={@cancelling?}
        >
          {gettext("Cancel")}
        </.button>
        <.spinner
          :if={@scanning?}
          label={
            if(@migration_source,
              do: gettext("Loading migration snapshot…"),
              else: gettext("Scanning library roots…")
            )
          }
        />
        <span
          :if={match?({:migration, :readarr}, @mode) and @scanning? and @readarr_progress}
          id="readarr-scan-progress"
          class="text-sm text-base-content/70"
          aria-live="polite"
        >
          {gettext("Resolving identities… %{resolved} of %{total} matched, continuing…",
            resolved: @readarr_progress.resolved,
            total: @readarr_progress.resolved + (@readarr_progress.remaining || 0)
          )}
        </span>
        <p class="text-sm text-base-content/70">
          {gettext(
            "Scanning and migration previews are read-only. Nothing changes until you confirm adoption."
          )}
        </p>
      </div>

      <div
        :if={@adoption_failures != []}
        id="adoption-failures"
        class="alert alert-error mb-6 items-start"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p class="font-semibold">{gettext("Some files could not be adopted")}</p>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
            <li :for={failure <- @adoption_failures}>
              <span class="font-mono">{adoption_failure_label(failure)}</span>
              <span> — {adoption_failure_text(failure)}</span>
            </li>
          </ul>
        </div>
      </div>

      <.empty_state
        :if={not @scanned? and not @scanning?}
        icon="hero-folder-magnifying-glass"
        title={gettext("Ready to scan")}
        message={gettext("Cinder will compare video files with the paths it already manages.")}
      />

      <div :if={@scanned? and Enum.sum(Map.values(@counts)) == 0} id="no-unmanaged-files">
        <.empty_state
          icon="hero-check-circle"
          title={gettext("No unmanaged files found")}
          message={gettext("Every discovered video file is already managed by Cinder.")}
        />
      </div>

      <section
        :if={@scanned? and match?({:migration, _source}, @mode)}
        id="migration-summary"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
        aria-labelledby="migration-summary-heading"
      >
        <h2 id="migration-summary-heading" class="text-lg font-semibold">
          {gettext("%{source} migration preview", source: source_label(@migration_source))}
        </h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "Ready: %{ready} · Needs decision: %{decision} · Blocked: %{blocked} · Already managed: %{managed}",
            ready: @counts.auto_matched,
            decision: @counts.ambiguous,
            blocked: @counts.unmatched,
            managed: @counts.already_managed
          )}
        </p>
        <ul
          :if={@migration_source == :sonarr}
          id="migration-series-counts"
          phx-update="stream"
          class="mt-3 space-y-1 text-sm"
        >
          <li :for={{dom_id, summary} <- @streams.migration_series_counts} id={dom_id}>
            <span class="font-medium">{summary.title}</span>
            <span class="text-base-content/70">
              {gettext(
                "Ready: %{ready}; Needs decision: %{decision}; Blocked: %{blocked}; Already managed: %{managed}",
                ready: summary.counts.ready,
                decision: summary.counts.needs_decision,
                blocked: summary.counts.blocked,
                managed: summary.counts.already_managed
              )}
            </span>
          </li>
        </ul>
      </section>

      <div
        :if={@migration_source == :readarr and @migration_deferred.count > 0}
        id="migration-deferred-bibliography"
        class="alert alert-info mb-6 items-start"
        role="status"
      >
        <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p>
            {ngettext(
              "%{count} additional monitored work was not imported; use per-author monitoring policy after cutover.",
              "%{count} additional monitored works were not imported; use per-author monitoring policy after cutover.",
              @migration_deferred.count,
              count: @migration_deferred.count
            )}
          </p>
          <p :if={map_size(@migration_deferred.links) > 0} class="mt-1 text-sm">
            <.link
              :for={{author_id, work_id} <- @migration_deferred.links}
              navigate={~p"/books/#{work_id}"}
              id={"deferred-author-#{author_id}"}
              class="link mr-3"
            >
              {gettext("View migrated author")}
            </.link>
          </p>
        </div>
      </div>

      <.form
        :if={@mode == :filesystem and Enum.sum(Map.values(@counts)) > 0}
        for={@form}
        id="adoption-form"
        phx-submit="adopt"
        class="space-y-8"
      >
        <section :if={@counts.auto_matched > 0} aria-labelledby="auto-matches-heading">
          <h2 id="auto-matches-heading" class="mb-3 text-xl font-semibold">
            {gettext("Auto-matched")} ({@counts.auto_matched})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("Exact title and year matches are selected by default.")}
          </p>
          <div id="auto-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.auto_candidates}
              id={dom_id}
              class="card border border-base-300 bg-base-100"
            >
              <div class="card-body gap-3 p-4">
                <label class="flex min-h-11 cursor-pointer items-start gap-3">
                  <input
                    type="checkbox"
                    name="adoption[selected][]"
                    value={candidate.id}
                    checked
                    class="checkbox checkbox-primary mt-0.5"
                    aria-label={gettext("Adopt %{title}", title: title(candidate))}
                  />
                  <span class="min-w-0">
                    <span class="block font-semibold">{title(candidate)}</span>
                    <span class="text-sm text-base-content/70">
                      {kind_label(candidate.kind)} · {gettext("Matched to %{title}",
                        title: match_title(candidate.match)
                      )}
                    </span>
                  </span>
                </label>

                <ul :if={candidate.kind == :series} class="space-y-1 text-sm">
                  <li :for={file <- candidate.files} class="space-y-1">
                    <div class="flex flex-wrap gap-x-2">
                      <span class="font-mono">{Path.basename(file.path)}</span>
                      <span class="text-base-content/60">{file_label(file)}</span>
                      <span :if={file.status == :matched} class="text-success">
                        {gettext("Matched")}
                      </span>
                      <span :if={file.status == :unmatched} class="text-warning">
                        {gettext("Held: %{reason}", reason: reason_text(file.reason))}
                      </span>
                    </div>
                    <label
                      :if={Map.get(file, :part_candidates, []) != []}
                      class="flex flex-wrap items-center gap-2 text-sm"
                    >
                      <span>{gettext("Needs confirmation")}</span>
                      <select
                        id={"part-assignment-#{candidate.id}-#{file.id}"}
                        name={"adoption[parts][#{candidate.id}][#{file.id}]"}
                        class="select select-sm select-bordered"
                        aria-label={
                          gettext("Assign %{file} to an episode", file: Path.basename(file.path))
                        }
                      >
                        <option value="">{gettext("Held")}</option>
                        <option
                          :for={part <- file.part_candidates}
                          value={part.episode_number}
                        >
                          {part_label(part)}
                        </option>
                      </select>
                    </label>
                  </li>
                </ul>
              </div>
            </article>
          </div>
        </section>

        <section :if={@counts.ambiguous > 0} aria-labelledby="ambiguous-heading">
          <h2 id="ambiguous-heading" class="mb-3 text-xl font-semibold">
            {gettext("Needs confirmation")} ({@counts.ambiguous})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("Choose one TMDB result, or leave the item unselected to skip it.")}
          </p>
          <div id="ambiguous-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.ambiguous_candidates}
              id={dom_id}
              class="card border border-warning/40 bg-base-100"
            >
              <div class="card-body gap-3 p-4">
                <div>
                  <p class="font-semibold">{title(candidate)}</p>
                  <p class="text-sm text-base-content/70">{kind_label(candidate.kind)}</p>
                </div>
                <fieldset class="space-y-2">
                  <legend class="sr-only">
                    {gettext("TMDB match for %{title}", title: title(candidate))}
                  </legend>
                  <label
                    :for={match <- candidate.candidates}
                    class="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"adoption[chosen][#{candidate.id}]"}
                      value={match.tmdb_id}
                      class="radio radio-primary"
                    />
                    <span>
                      <span class="block">{match_title(match)}</span>
                      <span class="text-xs text-base-content/60">
                        {gettext("TMDB %{id}", id: match.tmdb_id)}
                      </span>
                    </span>
                  </label>
                  <p :if={candidate.candidates == []} class="text-sm text-warning">
                    {gettext("TMDB returned no candidates. This item will be skipped.")}
                  </p>
                </fieldset>
              </div>
            </article>
          </div>
        </section>

        <section :if={@counts.unmatched > 0} aria-labelledby="unmatched-heading">
          <h2 id="unmatched-heading" class="mb-3 text-xl font-semibold">
            {gettext("Held")} ({@counts.unmatched})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("These files cannot be adopted safely and will not be changed.")}
          </p>
          <div id="unmatched-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.unmatched_candidates}
              id={dom_id}
              class="card border border-error/30 bg-base-100"
            >
              <div class="card-body gap-2 p-4">
                <p class="font-semibold">{title(candidate)}</p>
                <p class="text-sm text-error">{reason_text(candidate.reason)}</p>
                <ul :if={candidate.kind == :series} class="space-y-1 text-sm">
                  <li :for={file <- candidate.files}>
                    <span class="font-mono">{Path.basename(file.path)}</span>
                    <span class="text-base-content/60"> · {reason_text(file.reason)}</span>
                  </li>
                </ul>
              </div>
            </article>
          </div>
        </section>

        <div :if={@counts.auto_matched + @counts.ambiguous > 0} class="flex items-center gap-3">
          <.button id="adopt-selected" type="submit" disabled={@adopting? or @scanning?}>
            {if @adopting?, do: gettext("Adopting…"), else: gettext("Adopt selected")}
          </.button>
          <.spinner :if={@adopting?} label={gettext("Adopting selected files…")} />
        </div>
      </.form>

      <div
        :if={match?({:migration, _source}, @mode) and Enum.sum(Map.values(@counts)) > 0}
        id="migration-adoption"
        class="space-y-8"
      >
        <section :if={@counts.auto_matched > 0} aria-labelledby="migration-ready-heading">
          <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
            <h2 id="migration-ready-heading" class="text-xl font-semibold">
              {gettext("Ready")} ({@counts.auto_matched})
            </h2>
            <div class="flex flex-wrap items-center gap-3">
              <span
                id="migration-ready-selected-count"
                class="text-sm text-base-content/70"
                aria-live="polite"
              >
                {gettext("%{selected} of %{total} selected",
                  selected: MapSet.size(@selected_ready),
                  total: @counts.auto_matched
                )}
              </span>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="select_all_ready"
                aria-label={gettext("Select all ready items")}
              >
                {gettext("Select all")}
              </.button>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="deselect_all_ready"
                aria-label={gettext("Deselect all ready items")}
              >
                {gettext("Deselect all")}
              </.button>
            </div>
          </div>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("Provider identities and file paths have one safe catalog target.")}
          </p>
          <div id="migration-ready-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.auto_candidates}
              id={dom_id}
              class="card border border-base-300 bg-base-100"
            >
              <div class="card-body gap-2 p-4">
                <label class="flex min-h-11 cursor-pointer items-start gap-3">
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@selected_ready, candidate.id)}
                    phx-click="toggle_ready"
                    phx-value-id={candidate.id}
                    class="checkbox checkbox-primary mt-0.5"
                    aria-label={gettext("Adopt %{title}", title: migration_title(candidate))}
                  />
                  <span class="min-w-0">
                    <span class="block font-semibold">{migration_title(candidate)}</span>
                    <span class="block truncate font-mono text-sm text-base-content/70">
                      {file_name(migration_path(candidate))}
                    </span>
                  </span>
                </label>
              </div>
            </article>
          </div>
          <.migration_pager
            bucket={:ready}
            page={@pages.ready}
            count={@counts.auto_matched}
            label={gettext("Ready")}
          />
        </section>

        <section :if={@counts.ambiguous > 0} aria-labelledby="migration-decision-heading">
          <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
            <h2 id="migration-decision-heading" class="text-xl font-semibold">
              {gettext("Needs decision")} ({@counts.ambiguous})
            </h2>
            <div class="flex flex-wrap items-center gap-3">
              <span
                id="migration-decisions-pending"
                class="text-sm text-base-content/70"
                aria-live="polite"
              >
                {ngettext(
                  "%{count} decision pending",
                  "%{count} decisions pending",
                  Adoption.undecided_count(@migration_buckets.needs_decision, @decisions)
                )}
              </span>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="apply_all"
                phx-value-choice="fold"
                aria-label={gettext("Apply Fold to all undecided items")}
              >
                {gettext("Apply Fold to all undecided")}
              </.button>
              <.button
                type="button"
                variant="neutral"
                size="sm"
                phx-click="apply_all"
                phx-value-choice="part"
                aria-label={gettext("Apply Part to all undecided items")}
              >
                {gettext("Apply Part to all undecided")}
              </.button>
            </div>
          </div>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext(
              "Sonarr split several TVDB episodes into files that map to one TMDB episode. Choose how to treat each extra file."
            )}
          </p>
          <div id="migration-decision-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.ambiguous_candidates}
              id={dom_id}
              class="card border border-warning/40 bg-base-100"
            >
              <div class="card-body gap-3 p-4">
                <div>
                  <p class="font-semibold">{migration_title(candidate)}</p>
                  <p class="font-mono text-sm text-base-content/70">
                    {gettext("Primary: %{file}", file: file_name(candidate.primary_file.path))}
                  </p>
                  <p
                    :for={file <- candidate.extra_files}
                    class="font-mono text-sm text-base-content/70"
                  >
                    {gettext("Extra: %{file}", file: file_name(file.path))}
                  </p>
                </div>
                <fieldset class="space-y-2">
                  <legend class="sr-only">
                    {gettext("Migration choice for %{title}", title: migration_title(candidate))}
                  </legend>
                  <label
                    :if={candidate.kind == :episode}
                    class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"migration-choice-#{candidate.id}"}
                      value="fold"
                      checked={Map.get(@decisions, candidate.id) == "fold"}
                      phx-click="set_decision"
                      phx-value-id={candidate.id}
                      phx-value-choice="fold"
                      class="radio radio-primary mt-0.5"
                    />
                    <span>
                      <span class="block font-medium">{gettext("Fold")}</span>
                      <span class="text-sm text-base-content/70">
                        {gettext(
                          "Adopt the authoritative primary, save both provider coordinates, and leave the extra file unmanaged."
                        )}
                      </span>
                    </span>
                  </label>
                  <label
                    :if={candidate.kind == :episode}
                    class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"migration-choice-#{candidate.id}"}
                      value="part"
                      checked={Map.get(@decisions, candidate.id) == "part"}
                      phx-click="set_decision"
                      phx-value-id={candidate.id}
                      phx-value-choice="part"
                      class="radio radio-primary mt-0.5"
                    />
                    <span>
                      <span class="block font-medium">{gettext("Part")}</span>
                      <span class="text-sm text-base-content/70">
                        {gettext("Adopt the extra file as an explicit part of the primary episode.")}
                      </span>
                    </span>
                  </label>
                  <label
                    :if={candidate.kind == :book}
                    class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"migration-choice-#{candidate.id}"}
                      value="preferred"
                      checked={Map.get(@decisions, candidate.id) == "preferred"}
                      phx-click="set_decision"
                      phx-value-id={candidate.id}
                      phx-value-choice="preferred"
                      class="radio radio-primary mt-0.5"
                    />
                    <span>
                      <span class="block font-medium">{gettext("Preferred format")}</span>
                      <span class="text-sm text-base-content/70">
                        {gettext(
                          "Adopt only the preferred format (EPUB, else AZW3, else MOBI). The other files are left untouched on disk."
                        )}
                      </span>
                    </span>
                  </label>
                  <label
                    :if={candidate.kind == :book}
                    class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
                  >
                    <input
                      type="radio"
                      name={"migration-choice-#{candidate.id}"}
                      value="all_formats"
                      checked={Map.get(@decisions, candidate.id) == "all_formats"}
                      phx-click="set_decision"
                      phx-value-id={candidate.id}
                      phx-value-choice="all_formats"
                      class="radio radio-primary mt-0.5"
                    />
                    <span>
                      <span class="block font-medium">{gettext("All formats")}</span>
                      <span class="text-sm text-base-content/70">
                        {gettext("Adopt every accepted-format file for this work.")}
                      </span>
                    </span>
                  </label>
                </fieldset>
              </div>
            </article>
          </div>
          <.migration_pager
            bucket={:needs_decision}
            page={@pages.needs_decision}
            count={@counts.ambiguous}
            label={gettext("Needs decision")}
          />
        </section>

        <section :if={@counts.unmatched > 0} aria-labelledby="migration-blocked-heading">
          <h2 id="migration-blocked-heading" class="mb-3 text-xl font-semibold">
            {gettext("Blocked")} ({@counts.unmatched})
          </h2>
          <p class="mb-3 text-sm text-base-content/70">
            {gettext("These source records cannot be adopted safely and will not be changed.")}
          </p>
          <div id="migration-blocked-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.unmatched_candidates}
              id={dom_id}
              class="card border border-error/30 bg-base-100"
            >
              <div class="card-body gap-2 p-4">
                <p class="font-semibold">{migration_title(candidate)}</p>
                <p class="font-mono text-sm text-base-content/70">
                  {file_name(migration_path(candidate))}
                </p>
                <p class="text-sm text-error">{reason_text(candidate.reason)}</p>
              </div>
            </article>
          </div>
          <.migration_pager
            bucket={:blocked}
            page={@pages.blocked}
            count={@counts.unmatched}
            label={gettext("Blocked")}
          />
        </section>

        <section
          :if={@counts.already_managed > 0}
          aria-labelledby="migration-managed-heading"
        >
          <h2 id="migration-managed-heading" class="mb-3 text-xl font-semibold">
            {gettext("Already managed")} ({@counts.already_managed})
          </h2>
          <div id="migration-managed-candidates" phx-update="stream" class="space-y-3">
            <article
              :for={{dom_id, candidate} <- @streams.managed_candidates}
              id={dom_id}
              class="card border border-success/30 bg-base-100"
            >
              <div class="card-body gap-1 p-4">
                <p class="font-semibold">{migration_title(candidate)}</p>
                <p class="font-mono text-sm text-base-content/70">
                  {file_name(migration_path(candidate))}
                </p>
              </div>
            </article>
          </div>
          <.migration_pager
            bucket={:already_managed}
            page={@pages.already_managed}
            count={@counts.already_managed}
            label={gettext("Already managed")}
          />
        </section>

        <div :if={@counts.auto_matched + @counts.ambiguous > 0} class="flex items-center gap-3">
          <.button
            id="adopt-migration-selected"
            type="button"
            phx-click="adopt_migration"
            disabled={@adopting? or @scanning?}
          >
            {if @adopting?, do: gettext("Adopting…"), else: gettext("Adopt selected")}
          </.button>
          <.spinner :if={@adopting?} label={gettext("Adopting selected files…")} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_after_adopt(%{assigns: %{mode: :filesystem}} = socket, _summary),
    do: start_scan(socket)

  defp refresh_after_adopt(
         %{assigns: %{mode: {:migration, source}}} = socket,
         summary
       ) do
    adopted = MapSet.new(Map.get(summary, :adopted_keys, []))
    stale = MapSet.new(Map.get(summary, :stale_keys, []))

    candidates =
      Enum.map(socket.assigns.candidates, fn candidate ->
        cond do
          MapSet.member?(adopted, candidate.key) ->
            %{candidate | status: :already_managed, reason: nil}

          MapSet.member?(stale, candidate.key) ->
            %{candidate | status: :blocked, reason: :stale_candidate}

          true ->
            candidate
        end
      end)

    put_migration_preview(socket, %{
      source: source,
      candidates: candidates,
      counts: migration_counts(candidates),
      series_counts: migration_series_counts(candidates),
      # Snapshot arithmetic (§B6b's `Readarr.summary/2`) unaffected by adopting a batch — carried
      # over rather than recomputed, since no fresh snapshot/summary was fetched by this refresh.
      deferred_bibliography_count: Map.get(socket.assigns.migration_deferred, :count, 0),
      deferred_bibliography_authors:
        Map.keys(Map.get(socket.assigns.migration_deferred, :links, %{}))
    })
  end

  defp migration_counts(candidates) do
    Map.new([:ready, :needs_decision, :blocked, :already_managed], fn status ->
      {status, Enum.count(candidates, &(&1.status == status))}
    end)
  end

  defp migration_series_counts(candidates) do
    candidates
    |> Enum.filter(&is_integer(Map.get(&1, :series_provider_id)))
    |> Enum.group_by(& &1.series_provider_id)
    |> Enum.map(fn {provider_id, grouped} ->
      %{
        provider_id: provider_id,
        title: grouped |> hd() |> Map.get(:title),
        counts: migration_counts(grouped)
      }
    end)
    |> Enum.sort_by(&{&1.title, &1.provider_id})
  end
end
