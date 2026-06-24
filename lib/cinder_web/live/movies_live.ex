defmodule CinderWeb.MoviesLive do
  @moduledoc """
  Admin movie management at `/movies`: list every watchlisted movie with its pipeline status,
  edit metadata, and cancel (active → `:cancelled` + client-remove) or delete (DB row) with an
  in-LiveView confirm step (mirrors RequestsLive's `denying` pattern — no data-confirm/JS). The
  active-set predicate (`Catalog.cancellable?/1`) drives whether the row offers Cancel vs Delete.
  Admin-gated by the `:admin` live_session. Subscribes to the `"movies"` topic so create/update/
  delete events keep an open list live.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       editing: nil,
       confirming: nil,
       form: nil
     )}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        form = to_form(Movie.changeset(movie, %{}))
        {:noreply, assign(socket, editing: movie.id, confirming: nil, form: form)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("save", %{"id" => id, "movie" => attrs}, socket) do
    case find(socket, id) do
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

  def handle_event("ask_cancel", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:cancel, id}, editing: nil)}
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:delete, id}, editing: nil)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_cancel", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find(socket, id),
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

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find(socket, id),
         {:ok, _} <- Catalog.delete_movie(movie, actor) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Movie deleted.")}
    else
      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete that movie.")}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find(socket, id) do
    Enum.find(socket.assigns.movies, &(to_string(&1.id) == to_string(id)))
  end

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Movies<:subtitle>Edit, cancel, or delete watchlisted movies.</:subtitle>
      </.header>

      <p :if={@movies == []} class="text-base-content/60">No movies yet.</p>

      <ul class="space-y-3">
        <li :for={m <- @movies} id={"movie-#{m.id}"} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{m.title}</span>
            <span :if={m.year} class="text-base-content/60">({m.year})</span>
            <.status_badge kind={:movie} status={m.status} />

            <div class="ml-auto flex gap-2">
              <button type="button" class="btn btn-xs" phx-click="edit" phx-value-id={m.id}>
                Edit
              </button>
              <button
                :if={Catalog.cancellable?(m)}
                type="button"
                class="btn btn-xs btn-warning"
                phx-click="ask_cancel"
                phx-value-id={m.id}
              >
                Cancel
              </button>
              <button
                :if={not Catalog.cancellable?(m)}
                type="button"
                class="btn btn-xs btn-error"
                phx-click="ask_delete"
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
            <button class="btn btn-sm btn-primary" type="submit">Save</button>
            <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit">Cancel</button>
          </.form>

          <div :if={@confirming == {:cancel, to_string(m.id)}} class="mt-3 flex items-center gap-2">
            <span class="text-sm">Cancel this movie and remove its download?</span>
            <button class="btn btn-sm btn-warning" phx-click="confirm_cancel" phx-value-id={m.id}>
              Confirm cancel
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
          </div>

          <div :if={@confirming == {:delete, to_string(m.id)}} class="mt-3 flex items-center gap-2">
            <span class="text-sm">Delete this movie's record? (Library files are left on disk.)</span>
            <button class="btn btn-sm btn-error" phx-click="confirm_delete" phx-value-id={m.id}>
              Confirm delete
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
