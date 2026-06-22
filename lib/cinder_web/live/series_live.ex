defmodule CinderWeb.SeriesLive do
  @moduledoc """
  Admin-only TV discovery, mounted at `/series`. Search TMDB for series and add them
  (with their season/episode tree) to the watchlist; added series link to the detail
  view where monitoring is configured.

  TV is admin-only direct-add in M4 (no requester/approval flow until M5), so this page
  lives in the `:admin` live_session. The add runs off-process via `start_async` because
  `Catalog.add_series_to_watchlist/2` is 1 + N synchronous TMDB calls (one per season).
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false, adding: MapSet.new())
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

  # phx-value is client-controlled: tolerate non-numeric input and ignore a re-add of a
  # series already in flight (the `adding` set also drives the per-card loading state).
  def handle_event("add", %{"tmdb_id" => tmdb_id}, socket) when is_binary(tmdb_id) do
    with {id, ""} <- Integer.parse(tmdb_id),
         false <- MapSet.member?(socket.assigns.adding, id) do
      {:noreply,
       socket
       |> update(:adding, &MapSet.put(&1, id))
       |> start_async({:add, id}, fn -> Catalog.add_series_to_watchlist(id) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:add, id}, {:ok, {:ok, series}}, socket) do
    {:noreply,
     socket
     |> update(:adding, &MapSet.delete(&1, id))
     |> update(:series, &prepend_unique(&1, series))
     |> put_flash(:info, "#{series.title} added.")}
  end

  def handle_async({:add, id}, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> update(:adding, &MapSet.delete(&1, id))
     |> put_flash(:error, "Couldn't add that series. Try again.")}
  end

  def handle_async({:add, id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:adding, &MapSet.delete(&1, id))
     |> put_flash(:error, "Adding the series crashed. Try again.")}
  end

  defp prepend_unique(series, new) do
    if Enum.any?(series, &(&1.id == new.id)), do: series, else: [new | series]
  end

  @impl true
  def render(assigns) do
    # tmdb_id => persisted series id, so a search hit already on the watchlist links to
    # its detail view instead of offering a redundant Add.
    assigns = assign(assigns, :added, Map.new(assigns.series, &{&1.tmdb_id, &1.id}))

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        TV series
        <:subtitle>Search and add shows, then set monitoring.</:subtitle>
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
          <.series_card :for={s <- @results} series={s}>
            <.result_action result={s} adding={@adding} added={@added} />
          </.series_card>
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

  attr :result, :map, required: true
  attr :adding, :any, required: true
  attr :added, :map, required: true

  defp result_action(assigns) do
    ~H"""
    <.link
      :if={@added[@result.tmdb_id]}
      navigate={~p"/series/#{@added[@result.tmdb_id]}"}
      class="btn btn-ghost btn-sm w-full"
    >
      Open →
    </.link>
    <button
      :if={!@added[@result.tmdb_id] and MapSet.member?(@adding, @result.tmdb_id)}
      class="btn btn-sm w-full"
      disabled
    >
      <span class="loading loading-spinner loading-xs"></span> Adding…
    </button>
    <button
      :if={!@added[@result.tmdb_id] and not MapSet.member?(@adding, @result.tmdb_id)}
      id={"add-#{@result.tmdb_id}"}
      phx-click="add"
      phx-value-tmdb_id={@result.tmdb_id}
      class="btn btn-primary btn-sm w-full"
    >
      Add
    </button>
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
