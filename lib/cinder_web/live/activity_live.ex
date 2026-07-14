defmodule CinderWeb.ActivityLive do
  @moduledoc """
  Admin live activity at `/activity`: the movie pipeline (live operation progress — each row links to
  `/movies/:id` for management) and in-flight TV downloads (grabs, delete-with-confirm),
  newest first — as cards, so it reflows cleanly on a phone. Merges the old `/status` and
  `/grabs` pages. Terminal-done movies (`:available`/`:cancelled`) drop off the pipeline —
  they live in `/library`; only in-flight or parked-needing-retry movies stay here.
  Delete routes through `Catalog.cancel_grab/1` (which also removes the tracked client
  download, so the freed episodes' re-grab doesn't collide with it). Mapping holds use the
  state-guarded `Catalog.cancel_mapping_grab/1`; verification holds reuse the regular durable
  cancel path and add only a guarded retry. Live via the `movies` + `series` topics.
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

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

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

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp in_pipeline?(%{status: status}), do: status not in @pipeline_done

  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_), do: gettext("Unknown series")
  defp grab_state(%{mapping_status: :needs_mapping}), do: :needs_mapping
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
            <.link
              navigate={~p"/movies/#{m.id}"}
              class="link link-hover w-full truncate sm:w-auto sm:min-w-0 sm:flex-1"
            >
              {m.title}<span :if={m.year} class="text-base-content/70"> ({m.year})</span>
            </.link>
            <.status_badge
              kind={:movie}
              status={m.status}
              progress={m.download_progress}
              speed={m.download_speed}
              eta={m.download_eta}
            />
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
              <span
                :if={g.mapping_status == :verification_blocked}
                class="badge badge-warning"
              >
                {gettext("Needs verification")}
              </span>
              <.link
                :if={g.mapping_status == :needs_mapping}
                navigate={~p"/activity/grabs/#{g.id}/mapping"}
                class="link link-hover text-sm"
              >
                {gettext("Review mapping")}
              </.link>
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
                {gettext("Cancel download")}
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
            <.confirm_action
              :if={@confirming == "mapping:#{g.id}"}
              id={"confirm-cancel-mapping-grab-#{g.id}"}
              on_confirm="confirm_cancel_mapping"
              on_cancel="dismiss_confirm"
              value={g.id}
              confirm_label={gettext("Cancel download")}
              variant="warning"
            >
              <:caveat>
                {gettext("Cancel this download? Its episodes will return to the wanted queue.")}
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
    </Layouts.app>
    """
  end
end
