defmodule CinderWeb.SeriesLive do
  @moduledoc """
  TV series search page, mounted at `/series`. Searches TMDB and links each result to
  the discovery detail page (`/series/tmdb/:tmdb_id`) where users can request seasons.
  Added series (already on the watchlist) are listed below with a link to their admin
  monitoring detail page.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false)
     |> assign(series: Catalog.list_series())}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    case Catalog.search_tv(query) do
      {:ok, results} ->
        {:noreply, assign(socket, query: query, results: results, search_error: false)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(query: query, search_error: true)
         |> put_flash(:error, "TMDB search failed. Try again.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        TV series
        <:subtitle>Search shows and request seasons.</:subtitle>
      </.header>

      <.link navigate={~p"/"} class="link mb-6 inline-block">← Movies</.link>

      <form id="tv-search-form" phx-change="search" phx-submit="search" class="mb-8">
        <input
          type="text"
          id="tv-query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          aria-label="Search TV series"
          placeholder="Search TV series…"
          class="input w-full"
        />
      </form>

      <section :if={@results != []} class="mb-10">
        <h2 class="sr-only">Search results</h2>
        <div id="tv-results" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <.link :for={s <- @results} navigate={~p"/series/tmdb/#{s.tmdb_id}"} class="block">
            <.series_card series={s}>
              <span class="link link-primary text-sm">View →</span>
            </.series_card>
          </.link>
        </div>
      </section>

      <p
        :if={@query != "" and @results == [] and not @search_error}
        class="mb-10 text-base-content/60"
      >
        No matches.
      </p>

      <h2 class="pb-4 text-lg font-semibold leading-8">Added series</h2>
      <p :if={@series == []} class="text-base-content/60">No series added yet.</p>
      <div id="series-list" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.link :for={s <- @series} navigate={~p"/series/#{s.id}"} class="block">
          <.series_card series={s}>
            <span class="link link-primary text-sm">Configure monitoring →</span>
          </.series_card>
        </.link>
      </div>
    </Layouts.app>
    """
  end

  attr :series, :map, required: true
  slot :inner_block

  defp series_card(assigns) do
    assigns = assign(assigns, :poster_base, @poster_base)

    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <figure>
        <img
          :if={@series.poster_path}
          src={@poster_base <> @series.poster_path}
          alt={@series.title}
          class="aspect-[2/3] w-full object-cover"
        />
        <div
          :if={!@series.poster_path}
          class="grid aspect-[2/3] w-full place-items-center bg-base-300 text-sm text-base-content/40"
        >
          No poster
        </div>
      </figure>
      <div class="card-body gap-2 p-3">
        <h3 class="text-sm font-semibold leading-tight">
          {@series.title}
          <span :if={@series.year} class="font-normal text-base-content/60">
            ({@series.year})
          </span>
        </h3>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
