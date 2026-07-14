defmodule CinderWeb.LibraryLive do
  @moduledoc """
  Admin managed-catalog at `/library`: every movie (cancel / delete; drill into
  `/movies/:id` for edit and pipeline actions) and every added series (cancel / delete; drill into
  `/series/:id` for per-episode monitoring). Merges the old `/movies` page and the Discover
  "Added series" block.
  Admin-gated by the `:admin` live_session; every mutation routes through the existing
  `Catalog` functions — no pipeline or gate change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Catalog.list_movies(),
       series: Catalog.list_series(),
       confirming: nil,
       delete_files: false
     )}
  end

  # --- movies ---
  @impl true
  def handle_event("ask_cancel_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :cancel, id})}

  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, delete_files: false)}

  def handle_event("confirm_cancel_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.cancel_movie(movie, actor) do
      {:noreply,
       socket
       |> assign(confirming: nil, movies: Catalog.list_movies())
       |> put_flash(:info, gettext("Movie cancelled."))}
    else
      {:error, :not_cancellable} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("That movie can't be cancelled."))}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't cancel that movie."))}
    end
  end

  def handle_event("confirm_delete_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <-
           Catalog.delete_movie(movie, actor, delete_files: socket.assigns.delete_files) do
      {:noreply,
       socket
       |> assign(confirming: nil, delete_files: false)
       |> put_flash(:info, gettext("Movie deleted."))}
    else
      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete that movie."))}
    end
  end

  # --- series ---
  def handle_event("ask_cancel_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :cancel, id})}

  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :delete, id}, delete_files: false)}

  def handle_event("confirm_cancel_series", %{"id" => id}, socket),
    do:
      run_series_op(
        socket,
        id,
        &Catalog.cancel_series/2,
        gettext("Series cancelled."),
        gettext("Couldn't cancel the series.")
      )

  def handle_event("confirm_delete_series", %{"id" => id}, socket) do
    flag = socket.assigns.delete_files

    run_series_op(
      socket,
      id,
      fn series, actor -> Catalog.delete_series(series, actor, delete_files: flag) end,
      gettext("Series deleted."),
      gettext("Couldn't delete the series.")
    )
  end

  # --- shared ---
  def handle_event("toggle_delete_files", _params, socket),
    do: {:noreply, assign(socket, delete_files: !socket.assigns.delete_files)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, delete_files: false)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert_by_id(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find_movie(socket, id), do: find_by_id(socket.assigns.movies, to_string(id))

  # /library is admin-gated by its route, so no in-handler role re-check (Discover needed
  # one because it lived on a non-admin route).
  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    actor = socket.assigns.current_scope.user
    series = find_by_id(socket.assigns.series, id)

    case series && op.(series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil, series: Catalog.list_series())
         |> put_flash(:info, ok_msg)}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, err_msg)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Library")}
        <:subtitle>{gettext("Manage movies and added series.")}</:subtitle>
      </.header>

      <section>
        <h2 class="pb-3 text-lg font-semibold">{gettext("Movies")}</h2>
        <.empty_state
          :if={@movies == []}
          icon="hero-film"
          title={gettext("No movies yet")}
          message={gettext("Requested movies appear here.")}
        />
        <div
          :if={@movies != []}
          id="movies-list"
          class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4"
        >
          <div
            :for={m <- @movies}
            id={"movie-#{m.id}"}
            class={[
              "space-y-2",
              @confirming in [
                {:movie, :cancel, to_string(m.id)},
                {:movie, :delete, to_string(m.id)}
              ] &&
                "col-span-2 sm:col-span-3 lg:col-span-4"
            ]}
          >
            <.link navigate={~p"/movies/#{m.id}"} class="block max-w-xs">
              <.media_card poster_path={m.poster_path} title={m.title} year={m.year} type={:movie}>
                <.status_badge
                  kind={:movie}
                  status={movie_badge_status(m)}
                  progress={m.download_progress}
                  speed={m.download_speed}
                  eta={m.download_eta}
                  class="h-auto break-words text-center"
                />
              </.media_card>
            </.link>

            <div class="flex flex-wrap gap-2">
              <.button
                :if={Catalog.cancellable?(m)}
                type="button"
                variant="warning"
                size="sm"
                phx-click="ask_cancel_movie"
                phx-value-id={m.id}
              >
                {gettext("Cancel")}
              </.button>
              <.button
                :if={not Catalog.cancellable?(m)}
                type="button"
                variant="danger"
                size="sm"
                phx-click="ask_delete_movie"
                phx-value-id={m.id}
              >
                {gettext("Delete")}
              </.button>
            </div>

            <.confirm_action
              :if={@confirming == {:movie, :cancel, to_string(m.id)}}
              id={"confirm-cancel-movie-#{m.id}"}
              on_confirm="confirm_cancel_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label={gettext("Cancel movie")}
              variant="warning"
            >
              <:caveat>{gettext("Cancel this movie and remove its download?")}</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:movie, :delete, to_string(m.id)}}
              id={"confirm-delete-movie-#{m.id}"}
              on_confirm="confirm_delete_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label={gettext("Delete")}
              checkbox_event="toggle_delete_files"
              checkbox_checked={@delete_files}
              checkbox_label={gettext("Also delete the file from disk")}
            >
              <:caveat>{gettext("Delete this movie's record?")}</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">{gettext("Series")}</h2>
        <.empty_state
          :if={@series == []}
          icon="hero-tv"
          title={gettext("No series added yet")}
          message={gettext("Add a show from Discover.")}
        />
        <div
          :if={@series != []}
          id="series-list"
          class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4"
        >
          <div
            :for={s <- @series}
            id={"series-row-#{s.id}"}
            class={[
              "space-y-2",
              @confirming in [
                {:series, :cancel, to_string(s.id)},
                {:series, :delete, to_string(s.id)}
              ] &&
                "col-span-2 sm:col-span-3 lg:col-span-4"
            ]}
          >
            <.link navigate={~p"/series/#{s.id}"} class="block max-w-xs">
              <.media_card poster_path={s.poster_path} title={s.title} year={s.year} type={:tv}>
                <.status_badge
                  kind={:monitored}
                  status={s.monitored}
                  class="h-auto break-words text-center"
                />
              </.media_card>
            </.link>

            <div class="flex flex-wrap gap-2">
              <.button
                type="button"
                variant="warning"
                size="sm"
                phx-click="ask_cancel_series"
                phx-value-id={s.id}
              >{gettext("Cancel")}</.button>
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="ask_delete_series"
                phx-value-id={s.id}
              >{gettext("Delete")}</.button>
            </div>

            <.confirm_action
              :if={@confirming == {:series, :cancel, to_string(s.id)}}
              id={"confirm-cancel-series-#{s.id}"}
              on_confirm="confirm_cancel_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label={gettext("Cancel & unmonitor")}
              variant="warning"
            >
              <:caveat>{gettext("Cancel & unmonitor this series?")}</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:series, :delete, to_string(s.id)}}
              id={"confirm-delete-series-#{s.id}"}
              on_confirm="confirm_delete_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label={gettext("Delete")}
              checkbox_event="toggle_delete_files"
              checkbox_checked={@delete_files}
              checkbox_label={gettext("Also delete files from disk")}
            >
              <:caveat>{gettext("Delete this series and its seasons/episodes?")}</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
