defmodule CinderWeb.LibraryLive do
  @moduledoc """
  Admin managed-catalog at `/library`: every watchlisted movie (inline edit / cancel /
  delete) and every added series (cancel / delete; drill into `/series/:id` for per-episode
  monitoring). Merges the old `/movies` page and the Discover "Added series" block.
  Admin-gated by the `:admin` live_session; every mutation routes through the existing
  `Catalog` functions — no pipeline or gate change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       series: Catalog.list_series(),
       editing: nil,
       confirming: nil,
       form: nil
     )}
  end

  # --- movies ---
  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case find_movie(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        {:noreply,
         assign(socket,
           editing: movie.id,
           confirming: nil,
           form: to_form(Movie.changeset(movie, %{}))
         )}
    end
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: nil)}

  def handle_event("save", %{"id" => id, "movie" => attrs}, socket) do
    case find_movie(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        case Catalog.update_movie(movie, attrs) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(editing: nil, form: nil, movies: Catalog.list_watchlist())
             |> put_flash(:info, "Movie updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("ask_cancel_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :cancel, id}, editing: nil)}

  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, editing: nil)}

  def handle_event("confirm_cancel_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.cancel_movie(movie, actor) do
      {:noreply,
       socket
       |> assign(confirming: nil, movies: Catalog.list_watchlist())
       |> put_flash(:info, "Movie cancelled.")}
    else
      {:error, :not_cancellable} ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "That movie can't be cancelled.")}

      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't cancel that movie.")}
    end
  end

  def handle_event("confirm_delete_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.delete_movie(movie, actor) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Movie deleted.")}
    else
      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete that movie.")}
    end
  end

  # --- series ---
  def handle_event("ask_cancel_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :cancel, id})}

  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :delete, id})}

  def handle_event("confirm_cancel_series", %{"id" => id}, socket),
    do:
      run_series_op(
        socket,
        id,
        &Catalog.cancel_series/2,
        "Series cancelled.",
        "Couldn't cancel the series."
      )

  def handle_event("confirm_delete_series", %{"id" => id}, socket),
    do:
      run_series_op(
        socket,
        id,
        &Catalog.delete_series/2,
        "Series deleted.",
        "Couldn't delete the series."
      )

  # --- shared ---
  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find_movie(socket, id),
    do: Enum.find(socket.assigns.movies, &(to_string(&1.id) == to_string(id)))

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  # /library is admin-gated by its route, so no in-handler role re-check (Discover needed
  # one because it lived on a non-admin route).
  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    actor = socket.assigns.current_scope.user
    series = Enum.find(socket.assigns.series, &(to_string(&1.id) == id))

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
        Library<:subtitle>Manage watchlisted movies and added series.</:subtitle>
      </.header>

      <section>
        <h2 class="pb-3 text-lg font-semibold">Movies</h2>
        <.empty_state
          :if={@movies == []}
          icon="hero-film"
          title="No movies yet"
          message="Requested movies appear here."
        />
        <ul :if={@movies != []} class="space-y-3">
          <li :for={m <- @movies} id={"movie-#{m.id}"} class="card bg-base-200 p-4">
            <div class="flex flex-wrap items-center gap-3">
              <span class="font-semibold">{m.title}</span>
              <span :if={m.year} class="text-base-content/60">({m.year})</span>
              <.status_badge kind={:movie} status={m.status} />
              <div class="ml-auto flex gap-2">
                <button type="button" class="btn btn-xs" phx-click="edit" phx-value-id={m.id}>Edit</button>
                <button
                  :if={Catalog.cancellable?(m)}
                  type="button"
                  class="btn btn-xs btn-warning"
                  phx-click="ask_cancel_movie"
                  phx-value-id={m.id}
                >
                  Cancel
                </button>
                <button
                  :if={not Catalog.cancellable?(m)}
                  type="button"
                  class="btn btn-xs btn-error"
                  phx-click="ask_delete_movie"
                  phx-value-id={m.id}
                >
                  Delete
                </button>
              </div>
            </div>

            <.form
              :if={@editing == m.id}
              for={@form}
              id={"movie-form-#{m.id}"}
              phx-submit="save"
              phx-value-id={m.id}
              class="mt-3 flex flex-wrap items-end gap-2"
            >
              <.input field={@form[:title]} type="text" label="Title" />
              <.input field={@form[:year]} type="number" label="Year" />
              <button class="btn btn-sm btn-primary" type="submit" phx-disable-with="Saving…">Save</button>
              <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit">Cancel edit</button>
            </.form>

            <.confirm_action
              :if={@confirming == {:movie, :cancel, to_string(m.id)}}
              id={"confirm-cancel-movie-#{m.id}"}
              on_confirm="confirm_cancel_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label="Cancel movie"
              variant="warning"
            >
              <:caveat>Cancel this movie and remove its download?</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:movie, :delete, to_string(m.id)}}
              id={"confirm-delete-movie-#{m.id}"}
              on_confirm="confirm_delete_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label="Delete"
            >
              <:caveat>Delete this movie's record? (Library files are left on disk.)</:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">Series</h2>
        <.empty_state
          :if={@series == []}
          icon="hero-tv"
          title="No series added yet"
          message="Add a show from Discover."
        />
        <div
          :if={@series != []}
          id="series-list"
          class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4"
        >
          <div :for={s <- @series} id={"series-row-#{s.id}"} class="space-y-2">
            <.link navigate={~p"/series/#{s.id}"} class="block">
              <.media_card poster_path={s.poster_path} title={s.title} year={s.year} type={:tv}>
                <span class="link link-primary text-sm">Configure monitoring →</span>
              </.media_card>
            </.link>

            <div class="flex gap-2">
              <button
                type="button"
                class="btn btn-sm btn-warning"
                phx-click="ask_cancel_series"
                phx-value-id={s.id}
              >Cancel</button>
              <button
                type="button"
                class="btn btn-sm btn-error"
                phx-click="ask_delete_series"
                phx-value-id={s.id}
              >Delete</button>
            </div>

            <.confirm_action
              :if={@confirming == {:series, :cancel, to_string(s.id)}}
              id={"confirm-cancel-series-#{s.id}"}
              on_confirm="confirm_cancel_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Cancel & unmonitor"
              variant="warning"
            >
              <:caveat>Cancel & unmonitor this series?</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:series, :delete, to_string(s.id)}}
              id={"confirm-delete-series-#{s.id}"}
              on_confirm="confirm_delete_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Delete"
            >
              <:caveat>Delete this series record? (Library files are left on disk.)</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
