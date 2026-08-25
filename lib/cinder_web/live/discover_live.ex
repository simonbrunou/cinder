defmodule CinderWeb.DiscoverLive do
  @moduledoc """
  Unified Discover surface, mounted at `/`. One search returns movies and TV in a mixed poster
  grid plus books in their own text-card section. Movie cards request inline, TV cards link to
  the season picker, and book cards link to their provider-backed discovery page.
  """
  use CinderWeb, :live_view

  import CinderWeb.BookComponents
  import CinderWeb.DiscoverComponents
  import CinderWeb.LiveHelpers, only: [book_badge_state: 2, latest_status_by: 2]
  import CinderWeb.RequestHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Books
  alias Cinder.Catalog
  alias Cinder.Catalog.Genres
  alias Cinder.LibraryKind
  alias Cinder.Settings

  require Logger

  @picks Language.preferences()
  @book_kinds LibraryKind.books()

  # `cancel_async/3` unlinks and kills, but it neither demonitors nor drops the private entry, so
  # the task's DOWN still arrives as an `{:exit, reason}` result. A follow-on `start_async` under
  # the same name replaces the stored ref and LiveView prunes the stale message — but the branch
  # that only cancels (query fell below the floor) has nothing to replace it, so the DOWN lands on
  # `handle_async/3` and would report a books outage the user never had. One attribute for both
  # the reason and the clause that swallows it, so the two cannot drift apart.
  @superseded {:shutdown, :superseded}

  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap.
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      Cinder.Requests.subscribe()
      # A book target moves without a request event behind it (an admin approving elsewhere, and
      # from B4 an import flipping :monitored → :available). Without this the card badge and the
      # work page — which do share one fold — still drift apart on a live page.
      Books.subscribe_targets()
    end

    socket =
      socket
      |> assign(
        query: "",
        results: [],
        book_results: [],
        books_state: :idle,
        book_states: %{},
        search_error: nil,
        tmdb_config_path: nil,
        filter: :all,
        trending: [],
        popular: [],
        top_rated: [],
        now_playing: [],
        popular_tv: [],
        top_rated_tv: [],
        genre_media_type: :movie,
        selected_genre_id: nil,
        genre_results: [],
        movie_profiles: Catalog.list_profiles(:movies)
      )
      |> assign_request_state()

    {:ok, maybe_load_rails(socket)}
  end

  # The landing rails (trending + popular/top-rated/now-playing) fill the otherwise-empty
  # grid; each fetched off-process (its own start_async) so a slow TMDB can't hold up mount
  # and one rail's failure can't block the others, only on the connected mount (one fetch
  # each, not two).
  defp maybe_load_rails(socket) do
    if connected?(socket) do
      locale = socket.assigns.locale

      socket
      |> start_async(:trending, fn -> Catalog.trending(locale) end)
      |> start_async(:popular, fn -> Catalog.popular_movies(locale) end)
      |> start_async(:top_rated, fn -> Catalog.top_rated_movies(locale) end)
      |> start_async(:now_playing, fn -> Catalog.now_playing_movies(locale) end)
      |> start_async(:popular_tv, fn -> Catalog.popular_tv(locale) end)
      |> start_async(:top_rated_tv, fn -> Catalog.top_rated_tv(locale) end)
    else
      socket
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    locale = socket.assigns.locale

    socket =
      case Catalog.search_discover(query, locale) do
        {:ok, results} ->
          assign(socket,
            query: query,
            results: results,
            search_error: nil,
            tmdb_config_path: nil
          )

        {:error, _reason} ->
          put_search_error(socket, query)
      end

    {:noreply, maybe_search_books(socket, query)}
  end

  def handle_event("add", %{"tmdb_id" => tmdb_id} = params, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only match movies.
    preferred = normalize_language(params["preferred_language"])

    # Search every movie-bearing source: a rail-only movie (deduped out of
    # trending) must still be addable, not a silent no-op.
    %{
      results: results,
      trending: trending,
      popular: popular,
      top_rated: top_rated,
      now_playing: now_playing,
      genre_results: genre_results
    } = socket.assigns

    candidates = results ++ trending ++ popular ++ top_rated ++ now_playing ++ genre_results

    with {id, ""} <- Integer.parse(tmdb_id),
         {:ok, profile} <-
           normalize_profile(
             params["proposed_profile_id"] || params["proposed_media_profile"],
             :movies
           ),
         movie when not is_nil(movie) <-
           Enum.find(candidates, &(&1.type == :movie and &1.tmdb_id == id)) do
      {:noreply, add(socket, movie, preferred, profile)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("filter", %{"type" => type}, socket) do
    filter =
      case type do
        "movie" -> :movie
        "tv" -> :tv
        "person" -> :person
        "collection" -> :collection
        "book" -> :book
        "all" -> :all
        _ -> socket.assigns.filter
      end

    {:noreply, assign(socket, filter: filter)}
  end

  # Movies/TV toggle for the genre browser; switching media type clears the active
  # selection + its grid (movie and TV genre ids are distinct lists).
  def handle_event("genre_media_type", %{"type" => type}, socket) do
    media_type = if type == "tv", do: :tv, else: :movie

    {:noreply,
     assign(socket, genre_media_type: media_type, selected_genre_id: nil, genre_results: [])}
  end

  def handle_event("select_genre", %{"id" => id}, socket) when is_binary(id) do
    # phx-value is client-controlled; tolerate non-numeric/unknown ids instead of crashing
    # or spending a TMDB call on a forged genre id.
    media_type = socket.assigns.genre_media_type

    with {genre_id, ""} <- Integer.parse(id),
         true <- genre_valid?(media_type, genre_id) do
      case genre_fetch(media_type, genre_id, socket.assigns.locale) do
        {:ok, results} ->
          {:noreply, assign(socket, selected_genre_id: genre_id, genre_results: results)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(selected_genre_id: genre_id, genre_results: [])
           |> put_flash(:error, gettext("TMDB search failed. Try again."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ponytail: repeated queries reach providers; add a bounded search cache only when repeats are
  # measurably common enough to justify invalidation and memory limits.
  # One in-flight search per socket. The async name is constant and the superseded task is
  # cancelled rather than orphaned: `phx-debounce` is client-side only, so without this a client
  # typing (or scripting) faster than the providers answer accumulates 15s fetches nothing will
  # ever read. The query rides in the *result* instead of the name so the stale guard survives.
  defp maybe_search_books(socket, query) do
    socket = cancel_async(socket, :books, @superseded)
    trimmed = String.trim(query)

    if String.length(trimmed) >= 3 do
      socket
      |> assign(book_results: [], book_states: %{}, books_state: :loading)
      |> start_async(:books, fn -> {query, Books.search(trimmed)} end)
    else
      assign(socket, book_results: [], book_states: %{}, books_state: :idle)
    end
  end

  defp put_search_error(socket, query) do
    if tmdb_configured?() do
      socket
      |> assign(query: query, search_error: :unreachable, tmdb_config_path: nil)
      |> put_flash(:error, gettext("TMDB search failed. Try again."))
    else
      config_path = if Settings.setup_complete?(), do: ~p"/settings", else: ~p"/setup"

      socket
      |> assign(query: query, search_error: :unconfigured, tmdb_config_path: config_path)
      |> put_flash(:error, gettext("TMDB isn't configured yet."))
    end
  end

  # Settings overlays DB values onto this effective runtime config (including an env bootstrap),
  # so reading it recognizes either configuration source without exposing the secret itself.
  defp tmdb_configured? do
    token = :cinder |> Application.get_env(Cinder.Catalog.TMDB.HTTP, []) |> Keyword.get(:token)
    is_binary(token) and String.trim(token) != ""
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    {:noreply, patch_movie_status(socket, movie)}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, patch_movie_status(socket, movie)}
  end

  def handle_info({:movie_deleted, _id}, socket) do
    # Re-derive the status map — a stale entry would keep an "Available" badge on the
    # search-result card and never re-offer the Add button until remount.
    {:noreply, assign_movie_status(socket)}
  end

  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    {:noreply, socket |> assign_request_state() |> assign_book_states()}
  end

  def handle_info({:book_target_updated, _target}, socket) do
    {:noreply, assign_book_states(socket)}
  end

  # A season completing (episode import) or a series being removed can flip a TV card's badge.
  # Only availability can change on a series event — the user's requests and movies are untouched —
  # so recompute just that map, not the full request state.
  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, assign_available_series(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:books, {:ok, {query, _result}}, %{assigns: %{query: current}} = socket)
      when query != current do
    {:noreply, socket}
  end

  def handle_async(:books, {:ok, {_query, {:ok, results}}}, socket) do
    {:noreply,
     socket
     |> assign(book_results: results, books_state: :ready)
     |> assign_book_states()}
  end

  def handle_async(:books, {:ok, {_query, {:error, reason}}}, socket) do
    Logger.warning("Books search failed: #{inspect(reason)}")
    {:noreply, assign(socket, book_results: [], book_states: %{}, books_state: :error)}
  end

  def handle_async(:books, {:exit, @superseded}, socket), do: {:noreply, socket}

  def handle_async(:books, {:exit, reason}, socket) do
    Logger.warning("Books search crashed: #{inspect(reason)}")
    {:noreply, assign(socket, book_results: [], book_states: %{}, books_state: :error)}
  end

  def handle_async(:trending, {:ok, {:ok, results}}, socket) do
    {:noreply, assign(socket, trending: results)}
  end

  # Trending is decorative — on failure the page simply stays search-only, no flash.
  def handle_async(:trending, {:ok, {:error, reason}}, socket) do
    Logger.warning("Trending fetch failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:trending, {:exit, reason}, socket) do
    Logger.warning("Trending fetch crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:popular, result, socket),
    do: handle_rail_async("Popular movies", :popular, result, socket)

  def handle_async(:top_rated, result, socket),
    do: handle_rail_async("Top rated movies", :top_rated, result, socket)

  def handle_async(:now_playing, result, socket),
    do: handle_rail_async("Now playing", :now_playing, result, socket)

  def handle_async(:popular_tv, result, socket),
    do: handle_rail_async("Popular TV", :popular_tv, result, socket)

  def handle_async(:top_rated_tv, result, socket),
    do: handle_rail_async("Top rated TV", :top_rated_tv, result, socket)

  def handle_async({:add, _tmdb_id, title}, {:ok, result}, socket) do
    {:noreply, request_result(socket, title, result)}
  end

  def handle_async({:add, _tmdb_id, title}, {:exit, _reason}, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("Couldn't request %{title}. Try again.", title: title))}
  end

  # Shared by the popular/top-rated/now-playing rails — same decorative-failure shape as the
  # :trending clauses above: log and leave the section unrendered, never break the page.
  defp handle_rail_async(_label, key, {:ok, {:ok, results}}, socket),
    do: {:noreply, assign(socket, key, results)}

  defp handle_rail_async(label, _key, {:ok, {:error, reason}}, socket) do
    Logger.warning("#{label} fetch failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  defp handle_rail_async(label, _key, {:exit, reason}, socket) do
    Logger.warning("#{label} fetch crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Genre browsing dispatches on the media-type toggle: the movie and TV genre lists and their
  # /discover endpoints are distinct, so validation and fetch pick the matching one.
  defp genre_valid?(:tv, id), do: Genres.valid_tv_id?(id)
  defp genre_valid?(_movie, id), do: Genres.valid_id?(id)

  defp genre_fetch(:tv, id, locale), do: Catalog.tv_by_genre(id, locale)
  defp genre_fetch(_movie, id, locale), do: Catalog.movies_by_genre(id, locale)

  defp genre_list(:tv), do: Genres.tv_list()
  defp genre_list(_movie), do: Genres.list()

  defp assign_book_states(%{assigns: %{book_results: []}} = socket),
    do: assign(socket, book_states: %{})

  defp assign_book_states(socket) do
    references = Enum.map(socket.assigns.book_results, &{&1.provider, &1.foreign_id})
    work_ids = Books.work_ids_by_reference(references)
    target_states = work_ids |> Map.values() |> Books.target_statuses()

    request_states =
      socket.assigns.current_scope.user
      |> Cinder.Requests.list_for_user()
      |> Enum.filter(&(&1.target_type == "book"))
      |> latest_status_by(&{&1.target_id, &1.media_kind})

    states =
      for book <- socket.assigns.book_results,
          kind <- @book_kinds,
          work_id = work_ids[{to_string(book.provider), book.foreign_id}],
          state =
            book_badge_state(request_states[{work_id, kind}], target_states[{work_id, kind}]),
          state != :none,
          into: %{} do
        {{to_string(book.provider), book.foreign_id, kind}, state}
      end

    assign(socket, book_states: states)
  end

  # ponytail: only four valid values; default "original" on anything else (client-controlled).
  defp normalize_language(lang) when lang in @picks, do: lang
  defp normalize_language(_), do: "original"

  @impl true
  def render(assigns) do
    # Several TMDB lists commonly overlap (a blockbuster is often trending AND popular AND
    # top-rated); a title already shown in an earlier rail is dropped from a later one so the
    # same tmdb_id never renders twice at once. A movie's Add form id is keyed only by tmdb_id
    # (`add-form-#{tmdb_id}`), so two simultaneous movie copies would be a duplicate-DOM-id bug,
    # not just visual noise; TV cards have no id-bearing action (season-picker link only), so for
    # them it's purely visual. Dedupe keys on {type, tmdb_id} so a movie and a same-id show never
    # collide across the mixed trending rail.
    popular = dedupe(assigns.popular, assigns.trending)
    top_rated = dedupe(assigns.top_rated, assigns.trending ++ popular)
    now_playing = dedupe(assigns.now_playing, assigns.trending ++ popular ++ top_rated)
    popular_tv = dedupe(assigns.popular_tv, assigns.trending)
    top_rated_tv = dedupe(assigns.top_rated_tv, assigns.trending ++ popular_tv)

    genre_results =
      dedupe(
        assigns.genre_results,
        assigns.trending ++ popular ++ top_rated ++ now_playing ++ popular_tv ++ top_rated_tv
      )

    assigns =
      assign(assigns,
        filtered_results: filter_results(assigns.results, assigns.filter),
        filtered_book_results: filter_book_results(assigns.book_results, assigns.filter),
        popular: popular,
        top_rated: top_rated,
        now_playing: now_playing,
        popular_tv: popular_tv,
        top_rated_tv: top_rated_tv,
        genres: genre_list(assigns.genre_media_type),
        genre_results: genre_results
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.header>
        {gettext("Discover")}
        <:subtitle>{gettext("Search movies, TV, and books. Request what you want.")}</:subtitle>
      </.header>

      <form id="search-form" phx-change="search" phx-submit="search" class="relative mb-8">
        <label for="query" class="sr-only">{gettext("Search movies, TV, and books")}</label>
        <input
          type="text"
          id="query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          placeholder={gettext("Search movies, TV, and books…")}
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

      <div
        :if={@results != [] or @book_results != []}
        class="mb-4 flex flex-wrap gap-2"
        role="group"
        aria-label={gettext("Filter by type")}
      >
        <.button
          :for={
            {label, value} <- [
              {gettext("All"), :all},
              {gettext("Movies"), :movie},
              {gettext("TV"), :tv},
              {gettext("People"), :person},
              {gettext("Collections"), :collection},
              {gettext("Books"), :book}
            ]
          }
          phx-click="filter"
          phx-value-type={value}
          variant={if @filter == value, do: "primary", else: "ghost"}
          size="sm"
          aria-pressed={to_string(@filter == value)}
        >
          {label}
        </.button>
      </div>

      <section :if={@filtered_results != []} class="mb-10">
        <h2 class="sr-only">{gettext("Search results")}</h2>
        <.media_grid
          id="results"
          results={@filtered_results}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@filtered_book_results != []} class="mb-10" aria-labelledby="books-heading">
        <h2 id="books-heading" class="mb-4 text-lg font-semibold">{gettext("Books")}</h2>
        <.book_cards id="book-results" results={@filtered_book_results} states={@book_states} />
      </section>

      <section
        :if={@books_state == :error and @filter in [:all, :book]}
        id="books-search-error"
        class="mb-10 rounded-box bg-base-200 p-4 text-sm text-base-content/70"
        aria-labelledby="books-search-error-heading"
      >
        <h2 id="books-search-error-heading" class="font-semibold text-base-content">
          {gettext("Books are temporarily unavailable")}
        </h2>
        <p>{gettext("Movie and TV results are still available. Try the book search again later.")}</p>
      </section>

      <section :if={@query == "" and @trending != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-arrow-trending-up" class="size-5 text-primary" />
          {gettext("Trending this week")}
        </h2>
        <.media_grid
          id="trending"
          results={@trending}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == "" and @popular != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-fire" class="size-5 text-primary" />
          {gettext("Popular movies")}
        </h2>
        <.media_grid
          id="popular"
          results={@popular}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == "" and @top_rated != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-star" class="size-5 text-primary" />
          {gettext("Top rated movies")}
        </h2>
        <.media_grid
          id="top-rated"
          results={@top_rated}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == "" and @now_playing != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-play-circle" class="size-5 text-primary" />
          {gettext("Now playing")}
        </h2>
        <.media_grid
          id="now-playing"
          results={@now_playing}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == "" and @popular_tv != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-fire" class="size-5 text-primary" />
          {gettext("Popular TV")}
        </h2>
        <.media_grid
          id="popular-tv"
          results={@popular_tv}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == "" and @top_rated_tv != []} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-star" class="size-5 text-primary" />
          {gettext("Top rated TV")}
        </h2>
        <.media_grid
          id="top-rated-tv"
          results={@top_rated_tv}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <section :if={@query == ""} class="mb-10">
        <h2 class="mb-4 flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-tag" class="size-5 text-primary" />
          {gettext("Browse by genre")}
        </h2>
        <div
          class="mb-4 flex flex-wrap gap-2"
          role="group"
          aria-label={gettext("Genre media type")}
        >
          <.button
            :for={{label, value} <- [{gettext("Movies"), :movie}, {gettext("TV"), :tv}]}
            type="button"
            phx-click="genre_media_type"
            phx-value-type={value}
            variant={if @genre_media_type == value, do: "primary", else: "ghost"}
            size="sm"
            aria-pressed={to_string(@genre_media_type == value)}
          >
            {label}
          </.button>
        </div>
        <.genre_chips genres={@genres} selected_id={@selected_genre_id} />
        <.media_grid
          :if={@genre_results != []}
          id="genre-results"
          results={@genre_results}
          request_status={@request_status}
          movie_status={@movie_status}
          series_request_status={@series_request_status}
          available_series={@available_series}
          movie_profiles={@movie_profiles}
        />
      </section>

      <.empty_state
        :if={
          @query != "" and @filtered_results == [] and @filtered_book_results == [] and
            @books_state in [:idle, :ready] and is_nil(@search_error)
        }
        icon="hero-magnifying-glass"
        title={gettext("No matches")}
        message={gettext("No movies, shows, or books matched that search.")}
      />
      <.empty_state
        :if={@search_error == :unreachable}
        variant="search-error"
        title={gettext("Search failed")}
        message={gettext("TMDB didn't respond. Try again.")}
      />
      <.empty_state
        :if={@search_error == :unconfigured}
        variant="search-error"
        title={gettext("Search failed")}
        message={gettext("TMDB isn't configured yet.")}
      >
        <:cta>
          <.link
            id="configure-tmdb-link"
            navigate={@tmdb_config_path}
            class="link link-primary text-sm"
          >
            {if @tmdb_config_path == ~p"/setup",
              do: gettext("Add your API key in Setup →"),
              else: gettext("Add your API key in Settings →")}
          </.link>
        </:cta>
      </.empty_state>
    </Layouts.app>
    """
  end

  defp filter_results(results, :all), do: results
  defp filter_results(results, type), do: Enum.filter(results, &(&1.type == type))

  defp filter_book_results(results, filter) when filter in [:all, :book], do: results
  defp filter_book_results(_results, _filter), do: []

  # Drop any result whose {type, tmdb_id} already appears in an earlier rail, so a title
  # renders exactly once across the landing page (movies to avoid a duplicate Add-form id,
  # TV/others to avoid visual repeats).
  defp dedupe(results, shown) do
    shown_keys = MapSet.new(shown, &{&1.type, &1.tmdb_id})
    Enum.reject(results, &MapSet.member?(shown_keys, {&1.type, &1.tmdb_id}))
  end
end
