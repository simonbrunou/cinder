defmodule CinderWeb.WatchlistLive do
  @moduledoc """
  Search TMDB and build a watchlist. Mounted at `/`.

  Search results show the current user's relationship to each title (Pending /
  Approved / Available / Denied) instead of a bare Add button, cross-referencing the
  user's requests and the global movie rows. Live via the `movies` + `requests` topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap; full
    # reconciliation is Phase 5's dashboard concern.
    if connected?(socket) do
      Catalog.subscribe()
      Cinder.Requests.subscribe()
    end

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false)
     |> assign(watchlist: Catalog.list_watchlist())
     |> assign_request_state()}
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

    {:noreply, socket |> assign(watchlist: watchlist) |> patch_movie_status(movie)}
  end

  @impl true
  def handle_info({:movie_created, movie}, socket) do
    {:noreply, socket |> update(:watchlist, &[movie | &1]) |> patch_movie_status(movie)}
  end

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign_request_state(socket)}
  end

  @impl true
  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, update(socket, :watchlist, fn wl -> Enum.reject(wl, &(&1.id == id)) end)}
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
        socket |> put_flash(:info, "#{movie.title} added.") |> assign_request_state()

      {:ok, %{status: :pending}} ->
        socket
        |> put_flash(:info, "#{movie.title} requested — awaiting approval.")
        |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(
          socket,
          :error,
          "You've reached your request limit. Wait for approvals to clear."
        )

      {:error, _} ->
        put_flash(socket, :error, "#{movie.title} is already requested.")
    end
  end

  # The user's request status per target (latest wins — list_for_user is desc id) plus
  # the global movie pipeline status per tmdb_id; together they drive the per-title badge.
  defp assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    request_status = latest_request_status(Cinder.Requests.list_for_user(user))
    assign_movie_status(assign(socket, request_status: request_status))
  end

  # Read the full movie-status map from the DB (authoritative). Used on the infrequent
  # paths — mount, add, request events — where a just-approved/created movie may not be
  # in the locally-cached watchlist yet (its `:movie_created` broadcast rides a different
  # topic with no cross-topic ordering guarantee).
  defp assign_movie_status(socket) do
    assign(socket, movie_status: Map.new(Catalog.list_watchlist(), &{&1.tmdb_id, &1.status}))
  end

  # The high-frequency movie events carry the changed movie, so patch the one entry
  # rather than re-scanning the whole watchlist table on every pipeline transition.
  defp patch_movie_status(socket, movie) do
    assign(socket,
      movie_status: Map.put(socket.assigns.movie_status, movie.tmdb_id, movie.status)
    )
  end

  defp latest_request_status(requests) do
    Enum.reduce(requests, %{}, fn r, acc -> Map.put_new(acc, r.target_id, r.status) end)
  end

  # Precedence: an available movie outranks a stale denied/approved request.
  defp title_state(tmdb_id, request_status, movie_status) do
    cond do
      movie_status[tmdb_id] == :available -> :available
      request_status[tmdb_id] == :pending -> :pending
      request_status[tmdb_id] == :approved -> :approved
      request_status[tmdb_id] == :denied -> :denied
      true -> :none
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Cinder
        <:subtitle>Search movies and build your watchlist.</:subtitle>
      </.header>

      <nav :if={@current_scope.user.role == :admin} class="mb-6 flex gap-4">
        <.link navigate={~p"/series"} class="link">
          TV series →
        </.link>
      </nav>

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
            <.result_action
              state={title_state(m.tmdb_id, @request_status, @movie_status)}
              tmdb_id={m.tmdb_id}
            />
          </.movie_card>
        </div>
      </section>

      <.empty_state
        :if={@query != "" and @results == [] and not @search_error}
        icon="hero-magnifying-glass"
        title="No matches"
        message="No movies matched that search."
      />
      <.empty_state
        :if={@search_error}
        variant="search-error"
        title="Search failed"
        message="TMDB didn't respond. Try again."
      />

      <h2 class="pb-4 text-lg font-semibold leading-8">Watchlist</h2>
      <.empty_state
        :if={@watchlist == []}
        icon="hero-bookmark"
        title="Your watchlist is empty"
        message="Search above to add a movie."
      />
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.movie_card :for={m <- @watchlist} movie={m}>
          <.status_badge kind={:movie} status={m.status} />
        </.movie_card>
      </div>
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true
  attr :tmdb_id, :integer, required: true

  defp result_action(assigns) do
    ~H"""
    <.status_badge :if={@state != :none} kind={:request} status={@state} />
    <button
      :if={@state in [:none, :denied]}
      id={"add-#{@tmdb_id}"}
      phx-click="add"
      phx-value-tmdb_id={@tmdb_id}
      phx-disable-with="Adding…"
      class="btn btn-primary btn-sm w-full"
    >
      Add
    </button>
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
