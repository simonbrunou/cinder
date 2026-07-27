defmodule CinderWeb.LibraryAdoptionLive do
  @moduledoc """
  Admin workflow for scanning configured library roots and adopting confirmed
  movie and series matches without blocking the LiveView process.
  """

  use CinderWeb, :live_view

  alias Cinder.Catalog.Episode
  alias Cinder.Library.Adoption

  # Migration buckets can hold thousands of rows; render a bounded page per bucket and keep the
  # selection/decision state server-side (keyed by stable candidate id), independent of what the
  # current window streams.
  @page_size 50
  @empty_buckets %{ready: [], needs_decision: [], blocked: [], already_managed: []}
  @first_pages %{ready: 1, needs_decision: 1, blocked: 1, already_managed: 1}

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
       migration_buckets: @empty_buckets,
       selected_ready: MapSet.new(),
       decisions: %{},
       pages: @first_pages,
       undecided_skipped: 0,
       scanned?: false,
       scanning?: false,
       adopting?: false,
       adoption_failures: []
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
      when source in ["radarr", "sonarr"] do
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
    confirmed = confirmed_candidates(socket.assigns.candidates, params)

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
      when choice in ["fold", "part"] do
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
      when choice in ["fold", "part"] do
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
      confirmed_migration_commands(
        assigns.migration_buckets,
        assigns.selected_ready,
        assigns.decisions
      )

    case commands do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one match to adopt."))}

      commands ->
        undecided = undecided_count(assigns.migration_buckets.needs_decision, assigns.decisions)

        {:noreply,
         socket
         |> assign(adopting?: true, adoption_failures: [], undecided_skipped: undecided)
         |> start_async(:adopt, fn -> Adoption.adopt_migration(source, commands) end)}
    end
  end

  # Client-controlled events and malformed params are ignored rather than crashing the page.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:scan, {:ok, candidates}, socket) when is_list(candidates),
    do: {:noreply, put_candidates(socket, candidates)}

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
     |> start_scan()}
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
      selected_ready: MapSet.new(),
      decisions: %{},
      pages: @first_pages,
      undecided_skipped: 0,
      scanned?: false
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
      # Ready items are pre-selected (the previous default); the operator prunes with the header
      # controls. Decisions start empty — there is never a default fold/part.
      selected_ready: MapSet.new(ready, & &1.id),
      decisions: %{},
      pages: @first_pages,
      undecided_skipped: 0,
      counts: %{
        auto_matched: preview.counts.ready,
        ambiguous: preview.counts.needs_decision,
        unmatched: preview.counts.blocked,
        already_managed: preview.counts.already_managed
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

  defp confirmed_candidates(candidates, params) do
    selected = params |> Map.get("selected", []) |> List.wrap() |> parse_ids()
    chosen = Map.get(params, "chosen", %{})
    parts = Map.get(params, "parts", %{})

    Enum.flat_map(candidates, &confirm_candidate(&1, selected, chosen, parts))
  end

  # Commands are derived entirely from server-held selection/decision state (never a client-posted
  # list), so a windowed-away row that never rendered a checkbox is still honoured.
  defp confirmed_migration_commands(buckets, selected_ready, decisions) do
    ready_commands =
      for candidate <- buckets.ready,
          MapSet.member?(selected_ready, candidate.id),
          do: %{key: candidate.key}

    decision_commands =
      for candidate <- buckets.needs_decision,
          choice = Map.get(decisions, candidate.id),
          choice in ["fold", "part"],
          do: %{key: candidate.key, choice: choice}

    ready_commands ++ decision_commands
  end

  defp undecided_count(needs_decision, decisions),
    do: Enum.count(needs_decision, &(not Map.has_key?(decisions, &1.id)))

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

  defp confirm_candidate(
         %{status: :auto_matched, id: id} = candidate,
         selected,
         _chosen,
         parts
       ) do
    if MapSet.member?(selected, id) do
      [put_part_choices(candidate, candidate_choices(parts, id))]
    else
      []
    end
  end

  defp confirm_candidate(%{status: :ambiguous, id: id} = candidate, _selected, chosen, _parts)
       when is_map(chosen) do
    case parse_id(Map.get(chosen, to_string(id))) do
      nil -> []
      tmdb_id -> [Map.put(candidate, :chosen_tmdb_id, tmdb_id)]
    end
  end

  defp confirm_candidate(_candidate, _selected, _chosen, _parts), do: []

  defp candidate_choices(parts, candidate_id) when is_map(parts) do
    case Map.get(parts, to_string(candidate_id), %{}) do
      choices when is_map(choices) -> choices
      _ -> %{}
    end
  end

  defp candidate_choices(_parts, _candidate_id), do: %{}

  defp put_part_choices(candidate, choices) do
    files =
      Enum.map(Map.get(candidate, :files, []), fn file ->
        target = parse_id(Map.get(choices, to_string(Map.get(file, :id))))

        case Enum.find(Map.get(file, :part_candidates, []), &(&1.episode_number == target)) do
          nil ->
            file

          part_of ->
            %{file | status: :part, part_of: Map.take(part_of, [:season_number, :episode_number])}
        end
      end)

    Map.put(candidate, :files, files)
  end

  defp parse_ids(values) do
    values
    |> Enum.map(&parse_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
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
          id="scan-radarr"
          type="button"
          variant="neutral"
          phx-click="scan_migration"
          phx-value-source="radarr"
          disabled={@scanning? or @adopting?}
        >
          {gettext("Preview Radarr")}
        </.button>
        <.button
          id="scan-sonarr"
          type="button"
          variant="neutral"
          phx-click="scan_migration"
          phx-value-source="sonarr"
          disabled={@scanning? or @adopting?}
        >
          {gettext("Preview Sonarr")}
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
                  undecided_count(@migration_buckets.needs_decision, @decisions)
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
                  <label class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2">
                    <input
                      type="radio"
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
                  <label class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2">
                    <input
                      type="radio"
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
end
