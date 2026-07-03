defmodule CinderWeb.ActivityLive do
  @moduledoc """
  Admin live activity at `/activity`: the movie pipeline (Retry on parked movies) and
  in-flight TV downloads (grabs, delete-with-confirm), newest first — as cards, so it
  reflows cleanly on a phone. Merges the old `/status` and `/grabs` pages. Read-mostly:
  Retry routes through the server-guarded `Catalog.retry_movie/1` and delete through
  `Catalog.cancel_grab/1` (which also removes the tracked client download, so the
  freed episodes' re-grab doesn't collide with it). Live via the `movies` + `series`
  topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog

  @parked [:no_match, :search_failed, :import_failed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       grabs: Catalog.list_grabs(),
       confirming: nil,
       searching_movie_id: nil
     )}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  # The manual-search panel forwards a chosen release back here (it owns no Catalog writes).
  # Re-resolve the movie from the live list (it may have moved on) before grabbing.
  def handle_info({:manual_grab, :movie, movie, release}, socket) do
    {level, msg} =
      case find_by_id(socket.assigns.movies, to_string(movie.id)) do
        nil -> {:error, gettext("That movie can't be grabbed right now.")}
        current -> grab_flash(Catalog.manual_grab_movie(current, release))
      end

    {:noreply, socket |> assign(searching_movie_id: nil) |> put_flash(level, msg)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp grab_flash({:ok, _movie}), do: {:info, gettext("Grabbing the selected release…")}

  defp grab_flash({:error, :not_grabbable}),
    do: {:error, gettext("That movie can't be grabbed right now.")}

  defp grab_flash({:error, _reason}), do: {:error, gettext("Couldn't grab that release.")}

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    # Look the movie up from the loaded list (string-compare ids, like confirm_delete) so a forged
    # non-numeric phx-value can't reach Repo.get/CastError — it just resolves to nil and no-ops.
    movie = find_by_id(socket.assigns.movies, id)

    # A guarded miss (the movie already re-entered the pipeline under this stale
    # snapshot) must not be silent — the row visibly doesn't reset otherwise.
    socket =
      case movie && Catalog.retry_movie(movie) do
        {:error, _} ->
          put_flash(socket, :error, gettext("Couldn't retry: that movie has already moved on."))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("set_movie_language", %{"_id" => id, "preferred_language" => lang}, socket)
      when lang in ["original", "french", "any"] do
    movie = find_by_id(socket.assigns.movies, id)
    if movie, do: Catalog.set_movie_language(movie, lang)
    {:noreply, socket}
  end

  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: id)}

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

  # Toggle the manual-search panel for a movie row (re-clicking the open row closes it).
  def handle_event("manual_search", %{"id" => id}, socket) do
    id = to_string(id)
    open = if socket.assigns.searching_movie_id == id, do: nil, else: id
    {:noreply, assign(socket, searching_movie_id: open)}
  end

  def handle_event("cancel_upgrade", %{"id" => id}, socket) do
    movie = find_by_id(socket.assigns.movies, id)
    if movie, do: Catalog.abort_upgrade(movie, socket.assigns.current_scope.user)
    {:noreply, socket}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp parked?(status), do: status in @parked
  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_), do: gettext("Unknown series")
  defp grab_state(%{content_path: nil}), do: :downloading
  defp grab_state(_), do: :downloaded

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
            <span class="w-full truncate sm:w-auto sm:min-w-0 sm:flex-1">
              {m.title}<span :if={m.year} class="text-base-content/70"> ({m.year})</span>
            </span>
            <.status_badge kind={:movie} status={m.status} />
            <.button
              :if={parked?(m.status)}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="retry"
              phx-value-id={m.id}
              phx-disable-with={gettext("Retrying…")}
            >
              {gettext("Retry")}
            </.button>
            <.button
              :if={m.status == :available or parked?(m.status)}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="manual_search"
              phx-value-id={m.id}
            >
              {gettext("Find a better match")}
            </.button>
            <.button
              :if={m.status == :upgrading}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="cancel_upgrade"
              phx-value-id={m.id}
            >
              {gettext("Cancel upgrade")}
            </.button>
            <form id={"movie-language-form-#{m.id}"} phx-change="set_movie_language" class="ml-auto">
              <input type="hidden" name="_id" value={m.id} />
              <.language_select value={m.preferred_language} class="select select-xs" />
            </form>
            <div :if={@searching_movie_id == to_string(m.id)} class="w-full">
              <.live_component
                module={CinderWeb.ManualSearchComponent}
                id={"ms-movie-#{m.id}"}
                mode={:movie}
                target={m}
              />
            </div>
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
              <.status_badge kind={:grab} status={grab_state(g)} />
              <span class="text-xs text-base-content/70">{g.download_protocol}</span>
              <span class="min-w-0 truncate text-xs text-base-content/70">{g.download_id}</span>
              <.button
                type="button"
                variant="danger"
                size="sm"
                class="ml-auto"
                phx-click="ask_delete"
                phx-value-id={g.id}
                phx-disable-with={gettext("Deleting…")}
              >
                {gettext("Delete")}
              </.button>
            </div>
            <.confirm_action
              :if={@confirming == to_string(g.id)}
              id={"confirm-delete-grab-#{g.id}"}
              on_confirm="confirm_delete"
              on_cancel="dismiss_confirm"
              value={g.id}
              confirm_label={gettext("Delete")}
            >
              <:caveat>{gettext("Delete this download? Its episodes are unlinked.")}</:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
