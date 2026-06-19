defmodule CinderWeb.StatusLive do
  @moduledoc """
  Live status dashboard: every requested movie and its pipeline state, updated in
  real time via PubSub. Mounted at `/status`.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()
    {:ok, assign(socket, movies: Catalog.list_watchlist())}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    movies = upsert_movie(socket.assigns.movies, movie)
    {:noreply, assign(socket, movies: movies)}
  end

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
    <Layouts.app flash={@flash}>
      <.header>
        Status
        <:subtitle>Every requested movie and its live pipeline state.</:subtitle>
      </.header>

      <.link navigate={~p"/"} class="link mb-6 inline-block">← Search &amp; add</.link>

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
            <td><.movie_status_badge status={m.status} /></td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
