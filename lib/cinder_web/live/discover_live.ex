defmodule CinderWeb.DiscoverLive do
  @moduledoc """
  Unified Discover surface, mounted at `/`. One search returns movies AND TV in a
  single mixed poster grid: movie cards request inline (Add → `Cinder.Requests`),
  TV cards link to the season picker (`/series/tmdb/:tmdb_id`). Below the grid: the
  movie watchlist. Live via the `movies` + `requests` topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

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

  def handle_event("add", %{"tmdb_id" => tmdb_id} = params, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only match movies.
    preferred = normalize_language(params["preferred_language"])

    with {id, ""} <- Integer.parse(tmdb_id),
         movie when not is_nil(movie) <-
           Enum.find(socket.assigns.results, &(&1.type == :movie and &1.tmdb_id == id)) do
      {:noreply, add(socket, movie, preferred)}
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

  # ponytail: only three valid values; default "original" on anything else (client-controlled).
  defp normalize_language(lang) when lang in ["original", "french", "any"], do: lang
  defp normalize_language(_), do: "original"

  defp add(socket, movie, preferred) do
    user = socket.assigns.current_scope.user

    attrs = %{
      target_type: "movie",
      target_id: movie.tmdb_id,
      title: movie.title,
      year: movie.year,
      poster_path: movie.poster_path,
      original_language: movie.original_language,
      preferred_language: preferred
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
          gettext("%{title} requested. Awaiting approval.", title: movie.title)
        )
        |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(
          socket,
          :error,
          gettext("You've reached your request limit. Wait for approvals to clear.")
        )

      {:error, %Ecto.Changeset{} = cs} ->
        # Only a duplicate-pending unique-constraint is the benign "already requested" case;
        # any other changeset failure is a real error, not a reassuring info toast.
        if duplicate_request?(cs) do
          put_flash(socket, :info, gettext("%{title} is already requested.", title: movie.title))
        else
          put_flash(
            socket,
            :error,
            gettext("Couldn't request %{title}. Try again.", title: movie.title)
          )
        end

      {:error, _} ->
        put_flash(
          socket,
          :error,
          gettext("Couldn't request %{title}. Try again.", title: movie.title)
        )
    end
  end

  # The pending-request unique index (requests_pending_unique) is the duplicate signal;
  # Ecto tags that error opt with `constraint: :unique`.
  defp duplicate_request?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  # The user's request status per target (latest wins) plus the global movie pipeline
  # status per tmdb_id; together they drive the per-title movie badge.
  defp assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    request_status = latest_status_by(Cinder.Requests.list_for_user(user), & &1.target_id)
    assign_movie_status(assign(socket, request_status: request_status))
  end

  # Read the full movie-status map from the DB (authoritative) rather than deriving it
  # from the cached `watchlist` assign. On the infrequent paths that call this — mount,
  # add, request events — a just-approved/created movie may not be in the cached watchlist
  # yet (its `:movie_created` broadcast rides the movies topic with no cross-topic ordering
  # guarantee vs the `:request_*` event), so the assign can be stale; the DB read isn't.
  defp assign_movie_status(socket) do
    assign(socket, movie_status: Catalog.movie_status_map())
  end

  defp patch_movie_status(socket, movie) do
    assign(socket,
      movie_status: Map.put(socket.assigns.movie_status, movie.tmdb_id, movie.status)
    )
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
        <:subtitle>{gettext("Search movies and TV. Request what you want to watch.")}</:subtitle>
      </.header>

      <form id="search-form" phx-change="search" phx-submit="search" class="relative mb-8">
        <label for="query" class="sr-only">{gettext("Search movies and TV")}</label>
        <input
          type="text"
          id="query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          placeholder={gettext("Search movies and TV…")}
          class="input input-lg w-full min-h-11 pr-12"
        />
        <%!-- Spinner during the (synchronous) TMDB roundtrip — the form carries the phx
              loading class, the existing app.css custom-variant toggles this descendant. --%>
        <span
          class="pointer-events-none absolute right-4 top-1/2 hidden -translate-y-1/2 text-base-content/60 phx-change-loading:block phx-submit-loading:block"
          aria-hidden="true"
        >
          <.icon name="hero-arrow-path" class="size-5 animate-spin" />
        </span>
      </form>

      <section :if={@results != []} class="mb-10">
        <h2 class="sr-only">{gettext("Search results")}</h2>
        <div id="results" class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
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
              title={r.title}
              original_language={r.original_language}
            />
            <.button
              :if={r.type == :tv}
              navigate={~p"/series/tmdb/#{r.tmdb_id}"}
              variant="primary"
              size="sm"
              class="w-full"
            >
              {gettext("View seasons")}<.icon name="hero-arrow-right" class="size-3.5" />
            </.button>
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

      <h2 class="pb-4 text-lg font-semibold">{gettext("Watchlist")}</h2>
      <.empty_state
        :if={@watchlist == []}
        icon="hero-bookmark"
        title={gettext("Your watchlist is empty")}
        message={gettext("Search above to add a movie.")}
      />
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
        <.media_card
          :for={m <- @watchlist}
          poster_path={m.poster_path}
          title={m.title}
          year={m.year}
        >
          <.status_badge kind={:movie} status={m.status} class="h-auto break-words text-center" />
        </.media_card>
      </div>
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true
  attr :tmdb_id, :integer, required: true
  attr :title, :string, required: true
  attr :original_language, :string, default: nil

  defp result_action(assigns) do
    ~H"""
    <.status_badge
      :if={@state != :none}
      kind={:request}
      status={@state}
      class="h-auto break-words text-center"
    />
    <form
      :if={@state in [:none, :denied]}
      id={"add-form-#{@tmdb_id}"}
      phx-submit="add"
      class="flex flex-col gap-1"
    >
      <input type="hidden" name="tmdb_id" value={@tmdb_id} />
      <.language_select original_label={original_option_label(@original_language)} />
      <.button
        type="submit"
        variant="primary"
        size="sm"
        class="w-full"
        aria-label={gettext("Add %{title}", title: @title)}
        phx-disable-with={gettext("Adding…")}
      >
        {gettext("Add")}
      </.button>
    </form>
    """
  end

  defp original_option_label(nil), do: gettext("Original")
  defp original_option_label("en"), do: gettext("Original (English)")
  defp original_option_label("fr"), do: gettext("Original (French)")
  defp original_option_label(_), do: gettext("Original")
end
