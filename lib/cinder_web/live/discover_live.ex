defmodule CinderWeb.DiscoverLive do
  @moduledoc """
  Unified Discover surface, mounted at `/`. One search returns movies AND TV in a
  single mixed poster grid: movie cards request inline (Add → `Cinder.Requests`),
  TV cards link to the season picker (`/series/tmdb/:tmdb_id`). Below the grid: the
  movie watchlist. Live via the `movies` + `requests` topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap.
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
    case Catalog.search_discover(query) do
      {:ok, results} ->
        {:noreply, assign(socket, query: query, results: results, search_error: false)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(query: query, search_error: true)
         |> put_flash(:error, gettext("TMDB search failed. Try again."))}
    end
  end

  def handle_event("add", %{"tmdb_id" => tmdb_id}, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only match movies.
    with {id, ""} <- Integer.parse(tmdb_id),
         movie when not is_nil(movie) <-
           Enum.find(socket.assigns.results, &(&1.type == :movie and &1.tmdb_id == id)) do
      {:noreply, add(socket, movie)}
    else
      _ -> {:noreply, socket}
    end
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    watchlist = Enum.map(socket.assigns.watchlist, &if(&1.id == movie.id, do: movie, else: &1))
    {:noreply, socket |> assign(watchlist: watchlist) |> patch_movie_status(movie)}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, socket |> update(:watchlist, &[movie | &1]) |> patch_movie_status(movie)}
  end

  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, update(socket, :watchlist, fn wl -> Enum.reject(wl, &(&1.id == id)) end)}
  end

  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign_request_state(socket)}
  end

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
        socket
        |> put_flash(:info, gettext("%{title} added.", title: movie.title))
        |> assign_request_state()

      {:ok, %{status: :pending}} ->
        socket
        |> put_flash(
          :info,
          gettext("%{title} requested — awaiting approval.", title: movie.title)
        )
        |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(
          socket,
          :error,
          gettext("You've reached your request limit. Wait for approvals to clear.")
        )

      {:error, _} ->
        put_flash(
          socket,
          :error,
          gettext("%{title} is already requested.", title: movie.title)
        )
    end
  end

  # The user's request status per target (latest wins) plus the global movie pipeline
  # status per tmdb_id; together they drive the per-title movie badge.
  defp assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    request_status = latest_request_status(Cinder.Requests.list_for_user(user))
    assign_movie_status(assign(socket, request_status: request_status))
  end

  # Read the full movie-status map from the DB (authoritative) rather than deriving it
  # from the cached `watchlist` assign. On the infrequent paths that call this — mount,
  # add, request events — a just-approved/created movie may not be in the cached watchlist
  # yet (its `:movie_created` broadcast rides the movies topic with no cross-topic ordering
  # guarantee vs the `:request_*` event), so the assign can be stale; the DB read isn't.
  defp assign_movie_status(socket) do
    assign(socket, movie_status: Map.new(Catalog.list_watchlist(), &{&1.tmdb_id, &1.status}))
  end

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
        {gettext("Discover")}
        <:subtitle>{gettext("Search movies and TV — request what you want to watch.")}</:subtitle>
      </.header>

      <form id="search-form" phx-change="search" phx-submit="search" class="mb-8">
        <input
          type="text"
          id="query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          aria-label={gettext("Search movies and TV")}
          placeholder={gettext("Search movies and TV…")}
          class="input input-lg w-full min-h-11"
        />
      </form>

      <section :if={@results != []} class="mb-10">
        <h2 class="sr-only">{gettext("Search results")}</h2>
        <div id="results" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <.media_card
            :for={r <- @results}
            poster_path={r.poster_path}
            title={r.title}
            year={r.year}
            type={r.type}
          >
            <.result_action
              :if={r.type == :movie}
              state={title_state(r.tmdb_id, @request_status, @movie_status)}
              tmdb_id={r.tmdb_id}
            />
            <.link
              :if={r.type == :tv}
              navigate={~p"/series/tmdb/#{r.tmdb_id}"}
              class="btn btn-primary btn-sm w-full"
            >
              {gettext("View seasons →")}
            </.link>
          </.media_card>
        </div>
      </section>

      <.empty_state
        :if={@query != "" and @results == [] and not @search_error}
        icon="hero-magnifying-glass"
        title={gettext("No matches")}
        message={gettext("No movies or shows matched that search.")}
      />
      <.empty_state
        :if={@search_error}
        variant="search-error"
        title={gettext("Search failed")}
        message={gettext("TMDB didn't respond. Try again.")}
      />

      <h2 class="pb-4 text-lg font-semibold leading-8">{gettext("Watchlist")}</h2>
      <.empty_state
        :if={@watchlist == []}
        icon="hero-bookmark"
        title={gettext("Your watchlist is empty")}
        message={gettext("Search above to add a movie.")}
      />
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.media_card
          :for={m <- @watchlist}
          poster_path={m.poster_path}
          title={m.title}
          year={m.year}
        >
          <.status_badge kind={:movie} status={m.status} />
        </.media_card>
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
      phx-disable-with={gettext("Adding…")}
      class="btn btn-primary btn-sm w-full"
    >
      {gettext("Add")}
    </button>
    """
  end
end
