defmodule CinderWeb.StatusLive do
  @moduledoc """
  Live status dashboard: every requested movie and its pipeline state, updated in
  real time via PubSub. Mounted at `/status`.
  """
  use CinderWeb, :live_view

  alias Cinder.{Catalog, Health}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()

    socket = assign(socket, movies: Catalog.list_watchlist(), health: :loading)
    {:ok, check_health(socket)}
  end

  # Health checks hit the network, so run them off the mount path in an async task
  # (only once connected — there's no live process to receive the result on the
  # static render). A down service can't block the page from rendering.
  defp check_health(socket) do
    if connected?(socket),
      do: start_async(socket, :health, &Health.check_all/0),
      else: socket
  end

  # Parked states a user can re-queue; mirrors Catalog's server-side guard so the
  # button only renders where retry_movie/1 will actually act.
  @parked [:no_match, :search_failed, :import_failed]

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    movies = upsert_movie(socket.assigns.movies, movie)
    {:noreply, assign(socket, movies: movies)}
  end

  @impl true
  def handle_info({:movie_deleted, id}, socket) do
    movies = Enum.reject(socket.assigns.movies, &(&1.id == id))
    {:noreply, assign(socket, movies: movies)}
  end

  # Catch-all: an unmatched topic message (StatusLive had none) must not crash the view.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:health, {:ok, results}, socket) do
    {:noreply, assign(socket, health: results)}
  end

  # The task itself failed (e.g. an impl resolution raised). Show one error row
  # rather than leaving the panel stuck on "Checking…".
  def handle_async(:health, {:exit, reason}, socket) do
    {:noreply, assign(socket, health: [%{label: "Health check", status: {:error, reason}}])}
  end

  @impl true
  def handle_event("recheck_health", _params, socket) do
    # Cancel an in-flight check first so a rapid re-click doesn't orphan the prior
    # (link-monitored) task until its own timeout. No-op if none is running.
    {:noreply, socket |> cancel_async(:health) |> assign(health: :loading) |> check_health()}
  end

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    # Re-fetch: the assigns row can be stale, and Catalog.retry_movie/1 guards
    # the status anyway. Ignore a missing/non-retryable movie — the PubSub
    # broadcast from a successful retry re-renders the row.
    with movie when not is_nil(movie) <- Catalog.get_movie_by_id(id) do
      Catalog.retry_movie(movie)
    end

    {:noreply, socket}
  end

  defp parked?(status), do: status in @parked

  defp upsert_movie(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)) do
      Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1))
    else
      [movie | movies]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Status
        <:subtitle>Every requested movie and its live pipeline state.</:subtitle>
      </.header>

      <.link navigate={~p"/"} class="link mb-6 inline-block">← Search &amp; add</.link>

      <section class="mb-6">
        <div class="flex items-center gap-3 mb-2">
          <h2 class="text-lg font-semibold">Service health</h2>
          <button
            id="recheck-health"
            type="button"
            class="btn btn-xs"
            phx-click="recheck_health"
          >
            Recheck
          </button>
        </div>

        <p :if={@health == :loading} class="text-base-content/60">Checking…</p>

        <ul
          :if={@health != :loading}
          id="service-health"
          class="menu menu-sm bg-base-200 rounded-box w-full"
        >
          <li :for={h <- @health}>
            <div class="flex items-center justify-between">
              <span>{h.label}</span>
              <.status_badge kind={:health} status={h.status} />
            </div>
          </li>
        </ul>
      </section>

      <p :if={@movies == []} class="text-base-content/60">No movies yet.</p>

      <table :if={@movies != []} id="status-table" class="table">
        <thead>
          <tr>
            <th>Title</th><th>Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={m <- @movies} id={"movie-#{m.id}"}>
            <td>
              {m.title}
              <span :if={m.year} class="text-base-content/60">({m.year})</span>
            </td>
            <td>
              <.status_badge kind={:movie} status={m.status} />
              <button
                :if={parked?(m.status)}
                type="button"
                class="btn btn-xs btn-ghost ml-2"
                phx-click="retry"
                phx-value-id={m.id}
              >
                Retry
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
