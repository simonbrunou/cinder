defmodule CinderWeb.DiscoverLive do
  @moduledoc """
  Unified Discover surface, mounted at `/`. One search returns movies AND TV in a
  single mixed poster grid: movie cards request inline (Add → `Cinder.Requests`),
  TV cards link to the season picker (`/series/tmdb/:tmdb_id`). Live via the
  `movies` + `requests` topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.DiscoverComponents
  import CinderWeb.RequestHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog

  require Logger

  @picks Language.preferences()

  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap.
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      Cinder.Requests.subscribe()
    end

    socket =
      socket
      |> assign(query: "", results: [], search_error: false, filter: :all, trending: [])
      |> assign_request_state()

    {:ok, maybe_load_trending(socket)}
  end

  # Trending fills the otherwise-empty landing grid; fetched off-process so a slow
  # TMDB can't hold up mount, and only on the connected mount (one fetch, not two).
  defp maybe_load_trending(socket) do
    if connected?(socket) do
      locale = socket.assigns.locale
      start_async(socket, :trending, fn -> Catalog.trending(locale) end)
    else
      socket
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    locale = socket.assigns.locale

    case Catalog.search_discover(query, locale) do
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
         {:ok, profile} <- normalize_profile(params["proposed_media_profile"]),
         movie when not is_nil(movie) <-
           Enum.find(
             socket.assigns.results ++ socket.assigns.trending,
             &(&1.type == :movie and &1.tmdb_id == id)
           ) do
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
        "all" -> :all
        _ -> socket.assigns.filter
      end

    {:noreply, assign(socket, filter: filter)}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
    {:noreply, assign_request_state(socket)}
  end

  # A season completing (episode import) or a series being removed can flip a TV card's badge.
  # Only availability can change on a series event — the user's requests and movies are untouched —
  # so recompute just that map, not the full request state.
  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, assign_available_series(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
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

  def handle_async({:add, _tmdb_id, title}, {:ok, result}, socket) do
    {:noreply, request_result(socket, title, result)}
  end

  def handle_async({:add, _tmdb_id, title}, {:exit, _reason}, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("Couldn't request %{title}. Try again.", title: title))}
  end

  # ponytail: only four valid values; default "original" on anything else (client-controlled).
  defp normalize_language(lang) when lang in @picks, do: lang
  defp normalize_language(_), do: "original"

  defp normalize_profile(nil), do: {:ok, nil}
  defp normalize_profile("auto"), do: {:ok, nil}
  defp normalize_profile("standard"), do: {:ok, :standard}
  defp normalize_profile("anime"), do: {:ok, :anime}
  defp normalize_profile(_), do: {:error, :invalid_media_profile}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, filtered_results: filter_results(assigns.results, assigns.filter))

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

      <div
        :if={@results != []}
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
              {gettext("Collections"), :collection}
            ]
          }
          phx-click="filter"
          phx-value-type={value}
          variant={if @filter == value, do: "primary", else: "ghost"}
          size="sm"
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
        />
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
        />
      </section>

      <.empty_state
        :if={@query != "" and @filtered_results == [] and not @search_error}
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
    </Layouts.app>
    """
  end

  defp filter_results(results, :all), do: results
  defp filter_results(results, type), do: Enum.filter(results, &(&1.type == type))
end
