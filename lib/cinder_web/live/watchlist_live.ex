defmodule CinderWeb.WatchlistLive do
  @moduledoc """
  Search TMDB and build a watchlist. Mounted at `/`.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(query: "", results: [])
     |> assign(watchlist: Catalog.list_watchlist())}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    case Catalog.search_movies(query) do
      {:ok, results} ->
        {:noreply, assign(socket, query: query, results: results)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(query: query)
         |> put_flash(:error, "TMDB search failed. Try again.")}
    end
  end

  def handle_event("add", %{"tmdb_id" => tmdb_id}, socket) do
    id = String.to_integer(tmdb_id)

    case Enum.find(socket.assigns.results, &(&1.tmdb_id == id)) do
      nil -> {:noreply, socket}
      movie -> {:noreply, add(socket, movie)}
    end
  end

  defp add(socket, movie) do
    case Catalog.add_to_watchlist(movie) do
      {:ok, saved} ->
        update(socket, :watchlist, &[saved | &1])

      {:error, _changeset} ->
        put_flash(socket, :error, "#{movie.title} is already on your watchlist.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Cinder
        <:subtitle>Search movies and build your watchlist.</:subtitle>
      </.header>

      <form id="search-form" phx-change="search" phx-submit="search" class="mb-8">
        <input
          type="text"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          placeholder="Search movies…"
          class="input w-full"
        />
      </form>

      <div :if={@results != []} id="results" class="grid grid-cols-2 sm:grid-cols-3 gap-4 mb-10">
        <.movie_card :for={m <- @results} movie={m}>
          <button
            id={"add-#{m.tmdb_id}"}
            phx-click="add"
            phx-value-tmdb_id={m.tmdb_id}
            class="btn btn-primary btn-sm w-full"
          >
            Add
          </button>
        </.movie_card>
      </div>

      <p :if={@query != "" and @results == []} class="mb-10 text-base-content/60">No matches.</p>

      <.header>Watchlist</.header>
      <p :if={@watchlist == []} class="text-base-content/60">Your watchlist is empty.</p>
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.movie_card :for={m <- @watchlist} movie={m}>
          <span class="badge badge-soft badge-sm">{m.status}</span>
        </.movie_card>
      </div>
    </Layouts.app>
    """
  end

  attr :movie, :map, required: true
  slot :inner_block

  defp movie_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <figure>
        <img
          :if={@movie.poster_path}
          src={poster_url(@movie.poster_path)}
          alt={@movie.title}
          class="aspect-[2/3] w-full object-cover"
        />
        <div
          :if={!@movie.poster_path}
          class="grid aspect-[2/3] w-full place-items-center bg-base-300 text-sm text-base-content/40"
        >
          No poster
        </div>
      </figure>
      <div class="card-body gap-2 p-3">
        <h3 class="text-sm font-semibold leading-tight">
          {@movie.title}
          <span :if={@movie.year} class="font-normal text-base-content/60">
            ({@movie.year})
          </span>
        </h3>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp poster_url(path), do: @poster_base <> path
end
