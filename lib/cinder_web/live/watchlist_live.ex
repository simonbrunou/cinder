defmodule CinderWeb.WatchlistLive do
  @moduledoc """
  Search TMDB and build a watchlist. Mounted at `/`.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap; full
    # reconciliation is Phase 5's dashboard concern.
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false)
     |> assign(watchlist: Catalog.list_watchlist())}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    case Catalog.search_movies(query) do
      {:ok, results} ->
        {:noreply, assign(socket, query: query, results: results, search_error: false)}

      {:error, _reason} ->
        # Keep prior results; flag the error so we don't also claim "No matches".
        {:noreply,
         socket
         |> assign(query: query, search_error: true)
         |> put_flash(:error, "TMDB search failed. Try again.")}
    end
  end

  def handle_event("add", %{"tmdb_id" => tmdb_id}, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input.
    with {id, ""} <- Integer.parse(tmdb_id),
         movie when not is_nil(movie) <- Enum.find(socket.assigns.results, &(&1.tmdb_id == id)) do
      {:noreply, add(socket, movie)}
    else
      _ -> {:noreply, socket}
    end
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    watchlist =
      Enum.map(socket.assigns.watchlist, fn m ->
        if m.id == movie.id, do: movie, else: m
      end)

    {:noreply, assign(socket, watchlist: watchlist)}
  end

  @impl true
  def handle_info({:movie_created, movie}, socket) do
    {:noreply, update(socket, :watchlist, &[movie | &1])}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp add(socket, movie) do
    user = socket.assigns.current_scope.user

    attrs = %{
      target_type: "movie",
      target_id: movie.tmdb_id,
      title: movie.title,
      year: movie.year,
      poster_path: movie.poster_path
    }

    case Cinder.Requests.create_request(user, attrs) do
      {:ok, %{status: :approved}} ->
        put_flash(socket, :info, "#{movie.title} added.")

      {:ok, %{status: :pending}} ->
        put_flash(socket, :info, "#{movie.title} requested — awaiting approval.")

      {:error, _} ->
        put_flash(socket, :error, "#{movie.title} is already requested.")
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

      <.link navigate={~p"/status"} class="link mb-6 inline-block">Status dashboard →</.link>

      <form id="search-form" phx-change="search" phx-submit="search" class="mb-8">
        <input
          type="text"
          id="query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          aria-label="Search movies"
          placeholder="Search movies…"
          class="input w-full"
        />
      </form>

      <section :if={@results != []} class="mb-10">
        <h2 class="sr-only">Search results</h2>
        <div id="results" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
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
      </section>

      <p
        :if={@query != "" and @results == [] and not @search_error}
        class="mb-10 text-base-content/60"
      >
        No matches.
      </p>

      <h2 class="pb-4 text-lg font-semibold leading-8">Watchlist</h2>
      <p :if={@watchlist == []} class="text-base-content/60">Your watchlist is empty.</p>
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.movie_card :for={m <- @watchlist} movie={m}>
          <.movie_status_badge status={m.status} />
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
