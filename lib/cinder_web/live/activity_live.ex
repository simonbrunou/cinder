defmodule CinderWeb.ActivityLive do
  @moduledoc """
  Admin live activity at `/activity`: the movie pipeline (live operation progress — each row links to
  `/movies/:id` for management) and in-flight TV downloads (grabs, delete-with-confirm),
  newest first — as cards, so it reflows cleanly on a phone. Merges the old `/status` and
  `/grabs` pages. Terminal-done movies (`:available`/`:cancelled`) drop off the pipeline —
  they live in `/library`; only in-flight or parked-needing-retry movies stay here.
  Delete routes through `Catalog.cancel_grab/1` (which also removes the tracked client
  download, so the freed episodes' re-grab doesn't collide with it). A mapping hold shows its
  reason inline and offers Retry import (`Catalog.retry_grab_mapping/1`, resolves next poller
  tick) or Discard (the state-guarded `Catalog.cancel_mapping_grab/1`); verification holds reuse
  the regular durable cancel path and add only a guarded retry. Titles held at search time on
  unsatisfiable Anime preferences (`anime_hold_reason`) show a "Needs preferences" badge with
  the reason — movies in the pipeline list, series in their own section (a held series has no
  movie row or grab to hang the badge on); no action needed here, the sweep clears the hold
  once preferences resolve. Live via the `movies` + `series` topics. The "Background sweeps"
  section is the exception — a point-in-time snapshot read once at mount (its `last_run`/`next_run`
  values go stale until the page is reloaded), since a 12h sweep is rarely caught mid-run.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog

  # Terminal-done: imported (in the Library) or cancelled — no in-flight work left, so
  # showing them in a *live pipeline* is just noise. Parked failures (`:no_match` etc.)
  # stay, since they need a Retry.
  @pipeline_done [:available, :cancelled]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Enum.filter(Catalog.list_movies(), &in_pipeline?/1),
       grabs: Catalog.list_grabs(),
       held_series: Catalog.list_anime_held_series(),
       jobs: Cinder.Jobs.statuses(),
       confirming: nil
     )}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    movies =
      if in_pipeline?(movie),
        do: upsert_by_id(socket.assigns.movies, movie),
        else: Enum.reject(socket.assigns.movies, &(&1.id == movie.id))

    {:noreply, assign(socket, movies: movies)}
  end

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket) do
    {:noreply,
     assign(socket, grabs: Catalog.list_grabs(), held_series: Catalog.list_anime_held_series())}
  end

  def handle_info({:series_deleted, _id}, socket) do
    {:noreply,
     assign(socket, grabs: Catalog.list_grabs(), held_series: Catalog.list_anime_held_series())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: id)}

  def handle_event("ask_cancel_mapping", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: "mapping:#{id}")}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    # cancel_grab also removes the tracked client download — a bare row delete would
    # leave it running, colliding with the freed episodes' re-grab. Re-read the row
    # first: a snapshot grab may have finished importing while the confirm sat open,
    # and cancelling THAT would remove a completed torrent (killing seeding) for nothing.
    {level, msg} =
      with %{} = snapshot <- find_by_id(socket.assigns.grabs, id),
           %{} = grab <- Catalog.get_grab(snapshot.id) do
        case Catalog.cancel_grab(grab) do
          {:ok, _} -> {:info, gettext("Download deleted.")}
          _ -> {:error, gettext("Couldn't delete the download.")}
        end
      else
        nil -> {:error, gettext("That download is already gone.")}
      end

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(level, msg)}
  end

  def handle_event("confirm_cancel_mapping", %{"id" => id}, socket) do
    {level, msg} =
      with %{} = grab <- find_by_id(socket.assigns.grabs, id),
           {:ok, _deleted} <- Catalog.cancel_mapping_grab(grab) do
        {:info, gettext("Download deleted.")}
      else
        _ -> {:error, gettext("The download could not be cancelled.")}
      end

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(level, msg)}
  end

  def handle_event("retry_verification", %{"id" => id}, socket) when is_binary(id) do
    {level, msg} =
      with {id, ""} <- Integer.parse(id),
           %{} = grab <- Catalog.get_grab(id),
           {:ok, _retried} <- Catalog.retry_grab_verification(grab) do
        {:info, gettext("Verification will retry shortly.")}
      else
        _ -> {:error, gettext("The verification could not be retried.")}
      end

    {:noreply,
     socket
     |> assign(grabs: Catalog.list_grabs())
     |> put_flash(level, msg)}
  end

  def handle_event("retry_mapping", %{"id" => id}, socket) when is_binary(id) do
    {level, msg} =
      with {id, ""} <- Integer.parse(id),
           %{} = grab <- Catalog.get_grab(id),
           {:ok, _retried} <- Catalog.retry_grab_mapping(grab) do
        {:info, gettext("Import will retry shortly.")}
      else
        _ -> {:error, gettext("The import could not be retried.")}
      end

    {:noreply,
     socket
     |> assign(grabs: Catalog.list_grabs())
     |> put_flash(level, msg)}
  end

  def handle_event("retry", %{"id" => id}, socket) when is_binary(id) do
    socket =
      with {_id, ""} <- Integer.parse(id),
           %{} = movie <- find_by_id(socket.assigns.movies, id) do
        case Catalog.retry_movie(movie) do
          {:error, _} ->
            put_flash(socket, :error, gettext("Couldn't retry: that movie has already moved on."))

          _ ->
            socket
        end
      else
        _ -> put_flash(socket, :error, gettext("Couldn't retry that movie."))
      end

    {:noreply, socket}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp in_pipeline?(%{status: status}), do: status not in @pipeline_done

  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_), do: gettext("Unknown series")

  # A plain-English line under an in-flight/parked movie card: what phase it's in (with the search
  # attempt count) or why it's stuck and what to do. Complements the badge, which names the state.
  defp pipeline_hint(%{status: :searching, search_attempts: n}),
    do: gettext("Searching indexers (attempt %{n})", n: n + 1)

  defp pipeline_hint(%{status: :no_match}),
    do: gettext("No release matched your size/quality rules yet. Open it to retry or adjust.")

  defp pipeline_hint(%{status: :search_failed}),
    do: gettext("The indexer couldn't be reached after repeated tries. Open it to retry.")

  defp pipeline_hint(%{status: :import_failed}),
    do: gettext("The download finished but couldn't be imported. Open it to retry.")

  defp pipeline_hint(_movie), do: nil

  # Human label for a background sweep module (Cinder.Jobs).
  defp job_label(Cinder.Catalog.Refresher), do: gettext("Series metadata refresh")
  defp job_label(Cinder.Subtitles.Sweeper), do: gettext("Subtitle backfill")
  defp job_label(module), do: module |> Module.split() |> List.last()

  # Coarse relative times for the slow sweeps (they run hours apart — minute precision is plenty).
  defp last_run(nil), do: gettext("not yet")
  defp last_run(at), do: gettext("%{ago} ago", ago: coarse(DateTime.diff(DateTime.utc_now(), at)))

  defp next_run(nil, _interval), do: gettext("on schedule")

  defp next_run(at, interval) do
    case DateTime.diff(DateTime.add(at, interval, :millisecond), DateTime.utc_now()) do
      secs when secs <= 0 -> gettext("due now")
      secs -> gettext("in %{time}", time: coarse(secs))
    end
  end

  defp coarse(secs) when secs < 3600, do: gettext("%{n}m", n: max(div(secs, 60), 1))
  defp coarse(secs) when secs < 86_400, do: gettext("%{n}h", n: div(secs, 3600))
  defp coarse(secs), do: gettext("%{n}d", n: div(secs, 86_400))

  # Plain-English hold reason: which safety check failed, plus the offending file names or
  # episode ids — reused straight off the persisted `mapping_issue` (no separate display model).
  defp mapping_reason(%{"reason" => "unresolved_file", "relative_paths" => paths}),
    do: gettext("Couldn't match to an episode: %{paths}", paths: path_list(paths))

  defp mapping_reason(%{"reason" => "outside_authoritative_set", "relative_paths" => paths}),
    do: gettext("Matched an episode outside this release: %{paths}", paths: path_list(paths))

  defp mapping_reason(%{"reason" => "duplicate_episode_assignment", "relative_paths" => paths}),
    do: gettext("More than one file matched the same episode: %{paths}", paths: path_list(paths))

  defp mapping_reason(%{
         "reason" => "missing_episode_assignment",
         "candidate_episode_ids" => episode_ids
       }),
       do: gettext("No file found for episode id(s): %{ids}", ids: id_list(episode_ids))

  defp mapping_reason(%{
         "reason" => "reserved_set_divergence",
         "candidate_episode_ids" => episode_ids
       }),
       do:
         gettext(
           "The library's episodes no longer match what this grab reserved; affected episode id(s): %{ids}",
           ids: id_list(episode_ids)
         )

  defp mapping_reason(_issue), do: gettext("This release needs manual attention.")

  defp path_list(paths) when is_list(paths) and paths != [], do: Enum.join(paths, ", ")
  defp path_list(_paths), do: gettext("unknown file")

  defp id_list(ids) when is_list(ids) and ids != [], do: Enum.join(ids, ", ")
  defp id_list(_ids), do: gettext("unknown")

  # Plain-English search-time hold reason (`anime_hold_reason`, the AnimePreferences.resolve
  # error) naming the fix — cleared automatically by the next sweep once preferences resolve.
  defp anime_hold_reason("original_language_required"),
    do:
      gettext(
        "Dual audio needs this title's original language, which is unknown: on its detail page, choose an Audio pick other than \"%{dual}\", or fix the title's original-language metadata.",
        dual: language_label("dual")
      )

  defp anime_hold_reason("subtitle_language_required"),
    do:
      gettext(
        "Requiring embedded subtitles needs subtitle languages: configure them in Settings."
      )

  defp anime_hold_reason(_reason),
    do: gettext("The Anime release preferences can't be satisfied for this title.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Activity")}
        <:subtitle>{gettext("Live pipeline and in-flight downloads.")}</:subtitle>
      </.header>

      <section class="mt-2">
        <h2 class="pb-3 text-lg font-semibold">{gettext("Movie pipeline")}</h2>
        <.empty_state
          :if={@movies == []}
          icon="hero-film"
          title={gettext("No movies yet")}
          message={gettext("Requested movies move through here.")}
        />
        <ul :if={@movies != []} id="activity-movies" class="space-y-2">
          <li
            :for={m <- @movies}
            id={"movie-#{m.id}"}
            class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-3"
          >
            <.link
              navigate={~p"/movies/#{m.id}"}
              class="link link-hover w-full truncate sm:w-auto sm:min-w-0 sm:flex-1"
            >
              {m.title}<span :if={m.year} class="text-base-content/70"> ({m.year})</span>
            </.link>
            <.status_badge
              kind={:movie}
              status={movie_badge_status(m)}
              progress={m.download_progress}
              speed={m.download_speed}
              eta={m.download_eta}
            />
            <p
              :if={movie_badge_status(m) == :anime_hold}
              id={"movie-#{m.id}-hold-reason"}
              class="w-full text-sm text-base-content/70"
            >
              {anime_hold_reason(m.anime_hold_reason)}
            </p>
            <p
              :if={movie_badge_status(m) != :anime_hold and pipeline_hint(m)}
              id={"movie-#{m.id}-hint"}
              class="w-full text-sm text-base-content/70"
            >
              {pipeline_hint(m)}
            </p>
            <.button
              :if={
                movie_badge_status(m) in [
                  :no_match,
                  :search_failed,
                  :import_failed,
                  :verification_hold
                ]
              }
              id={"retry-movie-#{m.id}"}
              size="sm"
              phx-click="retry"
              phx-value-id={m.id}
              phx-disable-with={gettext("Retrying…")}
            >
              {gettext("Retry")}
            </.button>
          </li>
        </ul>
      </section>

      <section :if={@held_series != []} class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">{gettext("Held series")}</h2>
        <p class="pb-3 text-sm text-base-content/70">
          {gettext(
            "These series are skipped by the search sweep until their Anime preferences can be satisfied; the hold clears automatically once they can."
          )}
        </p>
        <ul id="activity-held-series" class="space-y-2">
          <li
            :for={s <- @held_series}
            id={"held-series-#{s.id}"}
            class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-3"
          >
            <.link
              navigate={~p"/series/#{s.id}"}
              class="link link-hover w-full truncate sm:w-auto sm:min-w-0 sm:flex-1"
            >
              {s.title}<span :if={s.year} class="text-base-content/70"> ({s.year})</span>
            </.link>
            <.status_badge kind={:series} status={:anime_hold} />
            <p
              id={"held-series-#{s.id}-reason"}
              class="w-full text-sm text-base-content/70"
            >
              {anime_hold_reason(s.anime_hold_reason)}
            </p>
          </li>
        </ul>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">{gettext("Downloads")}</h2>
        <.empty_state
          :if={@grabs == []}
          icon="hero-arrow-down-tray"
          title={gettext("No active downloads")}
          message={gettext("In-flight TV downloads show here.")}
        />
        <ul :if={@grabs != []} id="activity-grabs" class="space-y-3">
          <li :for={g <- @grabs} id={"grab-#{g.id}"} class="rounded-box bg-base-200/50 p-4">
            <div class="flex flex-wrap items-center gap-2">
              <span class="min-w-0 break-words font-semibold">{series_title(g)}</span>
              <.status_badge
                kind={:grab}
                status={grab_state(g)}
                progress={g.download_progress}
                speed={g.download_speed}
                eta={g.download_eta}
              />
              <span class="text-xs text-base-content/70">{g.download_protocol}</span>
              <span class="min-w-0 truncate text-xs text-base-content/70">{g.download_id}</span>
              <.button
                :if={g.mapping_status == :needs_mapping}
                id={"retry-mapping-grab-#{g.id}"}
                type="button"
                size="xs"
                phx-click="retry_mapping"
                phx-value-id={g.id}
              >
                {gettext("Retry import")}
              </.button>
              <.button
                :if={g.mapping_status == :needs_mapping}
                id={"ask-cancel-mapping-grab-#{g.id}"}
                type="button"
                variant="danger"
                size="sm"
                class="ml-auto"
                phx-click="ask_cancel_mapping"
                phx-value-id={g.id}
              >
                {gettext("Discard")}
              </.button>
              <.button
                :if={g.mapping_status == :verification_blocked}
                id={"retry-verification-grab-#{g.id}"}
                type="button"
                size="xs"
                phx-click="retry_verification"
                phx-value-id={g.id}
              >
                {gettext("Retry verification")}
              </.button>
              <.button
                :if={g.mapping_status != :needs_mapping}
                id={
                  if g.mapping_status == :verification_blocked,
                    do: "cancel-verification-grab-#{g.id}"
                }
                type="button"
                variant="danger"
                size="sm"
                class="ml-auto"
                phx-click="ask_delete"
                phx-value-id={g.id}
                phx-disable-with={gettext("Deleting…")}
              >
                {if g.mapping_status == :verification_blocked,
                  do: gettext("Cancel download"),
                  else: gettext("Delete")}
              </.button>
            </div>
            <p
              :if={g.mapping_status == :needs_mapping}
              id={"grab-#{g.id}-mapping-reason"}
              class="mt-2 text-sm text-base-content/70"
            >
              {mapping_reason(g.mapping_issue)}
            </p>
            <.confirm_action
              :if={@confirming == "mapping:#{g.id}"}
              id={"confirm-cancel-mapping-grab-#{g.id}"}
              on_confirm="confirm_cancel_mapping"
              on_cancel="dismiss_confirm"
              value={g.id}
              confirm_label={gettext("Discard")}
              variant="warning"
            >
              <:caveat>
                {gettext("Discard this download? Its episodes will return to the wanted queue.")}
              </:caveat>
            </.confirm_action>
            <.confirm_action
              :if={@confirming == to_string(g.id)}
              id={"confirm-delete-grab-#{g.id}"}
              on_confirm="confirm_delete"
              on_cancel="dismiss_confirm"
              value={g.id}
              confirm_label={
                if g.mapping_status == :verification_blocked,
                  do: gettext("Cancel download"),
                  else: gettext("Delete")
              }
            >
              <:caveat>
                {if g.mapping_status == :verification_blocked,
                  do: gettext("Cancel this download? Its episodes will return to the wanted queue."),
                  else: gettext("Delete this download? Its episodes are unlinked.")}
              </:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">{gettext("Background sweeps")}</h2>
        <p class="pb-3 text-sm text-base-content/70">
          {gettext(
            "Periodic maintenance that runs on its own: refreshing series metadata and backfilling subtitles."
          )}
        </p>
        <ul id="activity-jobs" class="space-y-2">
          <li
            :for={j <- @jobs}
            id={"job-#{j.module |> Module.split() |> List.last()}"}
            class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-x-4 gap-y-1"
          >
            <span class="w-full font-medium sm:w-auto sm:min-w-0 sm:flex-1">
              {job_label(j.module)}
            </span>
            <span class="text-sm text-base-content/70">
              {gettext("Last run: %{when}", when: last_run(j.last_run_at))}
            </span>
            <span class="text-sm text-base-content/70">
              {gettext("Next: %{when}", when: next_run(j.last_run_at, j.interval))}
            </span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
