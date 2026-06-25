defmodule CinderWeb.ActivityLive do
  @moduledoc """
  Admin live activity at `/activity`: the movie pipeline (Retry on parked movies) and
  in-flight TV downloads (grabs, delete-with-confirm), newest first — as cards, so it
  reflows cleanly on a phone. Merges the old `/status` and `/grabs` pages. Read-mostly:
  Retry routes through the server-guarded `Catalog.retry_movie/1` and delete through
  `Catalog.delete_grab/1`; no pipeline change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

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
       confirming: nil
     )}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    # Look the movie up from the loaded list (string-compare ids, like confirm_delete) so a forged
    # non-numeric phx-value can't reach Repo.get/CastError — it just resolves to nil and no-ops.
    movie = Enum.find(socket.assigns.movies, &(to_string(&1.id) == id))
    if movie, do: Catalog.retry_movie(movie)

    {:noreply, socket}
  end

  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: id)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    grab = Enum.find(socket.assigns.grabs, &(to_string(&1.id) == id))
    if grab, do: Catalog.delete_grab(grab)

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(:info, gettext("Grab deleted."))}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  defp parked?(status), do: status in @parked
  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_), do: "—"
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
            <span class="min-w-0 flex-1 truncate">
              {m.title}<span :if={m.year} class="text-base-content/50"> ({m.year})</span>
            </span>
            <.status_badge kind={:movie} status={m.status} />
            <button
              :if={parked?(m.status)}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="retry"
              phx-value-id={m.id}
              phx-disable-with={gettext("Retrying…")}
            >
              {gettext("Retry")}
            </button>
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
          <li :for={g <- @grabs} id={"grab-#{g.id}"} class="card bg-base-200 p-4">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-semibold">{series_title(g)}</span>
              <.status_badge kind={:grab} status={grab_state(g)} />
              <span class="text-xs text-base-content/50">{g.download_protocol}</span>
              <span class="text-xs text-base-content/50 truncate">{g.download_id}</span>
              <button
                type="button"
                class="btn btn-xs btn-error ml-auto"
                phx-click="ask_delete"
                phx-value-id={g.id}
                phx-disable-with={gettext("Deleting…")}
              >
                {gettext("Delete")}
              </button>
            </div>
            <.confirm_action
              :if={@confirming == to_string(g.id)}
              id={"confirm-delete-grab-#{g.id}"}
              on_confirm="confirm_delete"
              on_cancel="dismiss_confirm"
              value={g.id}
              confirm_label={gettext("Delete")}
            >
              <:caveat>{gettext("Delete this grab? Its episodes are unlinked.")}</:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
