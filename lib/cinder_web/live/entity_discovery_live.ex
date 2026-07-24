defmodule CinderWeb.EntityDiscoveryLive do
  @moduledoc """
  Drill-in page for a TMDB person or collection, mounted at
  `/person/tmdb/:tmdb_id` (live_action `:person`) and `/collection/tmdb/:tmdb_id`
  (live_action `:collection`). The two pages are structurally identical — parse the
  id, sync-fetch one entity from TMDB in `mount/3`, render a header plus a grid —
  and differ only in fetch fn, list field, and header. Grid + add/request flow
  reuse `DiscoverComponents.media_grid/1` and `RequestHelpers`, exactly like
  `DiscoverLive`. Mirrors `SeriesDiscoveryLive`'s defensive param parse and
  sync-fetch-in-mount with its 404-vs-outage flash split.
  """
  use CinderWeb, :live_view

  import CinderWeb.DiscoverComponents
  import CinderWeb.RequestHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog

  @picks Language.preferences()

  @impl true
  def mount(%{"tmdb_id" => raw}, _session, socket) do
    # The :tmdb_id param is client-controlled; a non-integer must not crash the page.
    with {tmdb_id, ""} <- Integer.parse(raw),
         {:ok, info} <- fetch_entity(socket.assigns.live_action, tmdb_id, socket.assigns.locale) do
      if connected?(socket) do
        Catalog.subscribe()
        Catalog.subscribe_series()
        Cinder.Requests.subscribe()
      end

      {:ok,
       socket
       |> assign(tmdb_id: tmdb_id, info: info)
       |> assign_request_state()}
    else
      # A TMDB outage is not "not found" — telling the user the entity doesn't exist
      # sends them away from a page that loads fine once TMDB is back.
      {:error, reason} when reason != {:tmdb_status, 404} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Couldn't reach TMDB. Please try again in a moment."))
         |> push_navigate(to: ~p"/")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, not_found_message(socket.assigns.live_action))
         |> push_navigate(to: ~p"/")}
    end
  end

  defp fetch_entity(:person, tmdb_id, locale), do: Catalog.get_person(tmdb_id, locale)
  defp fetch_entity(:collection, tmdb_id, locale), do: Catalog.get_collection(tmdb_id, locale)

  defp not_found_message(:person), do: gettext("Person not found.")
  defp not_found_message(:collection), do: gettext("Collection not found.")

  @impl true
  def handle_event("add", %{"tmdb_id" => tmdb_id} = params, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only match movies.
    preferred = normalize_language(params["preferred_language"])

    with {id, ""} <- Integer.parse(tmdb_id),
         {:ok, profile} <- normalize_profile(params["proposed_media_profile"]),
         movie when not is_nil(movie) <-
           Enum.find(grid_items(socket), &(&1.type == :movie and &1.tmdb_id == id)) do
      {:noreply, add(socket, movie, preferred, profile)}
    else
      _ -> {:noreply, socket}
    end
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp grid_items(%{assigns: %{live_action: :person, info: info}}), do: info.credits
  defp grid_items(%{assigns: %{live_action: :collection, info: info}}), do: info.parts

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    {:noreply, patch_movie_status(socket, movie)}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, patch_movie_status(socket, movie)}
  end

  def handle_info({:movie_deleted, _id}, socket) do
    {:noreply, assign_movie_status(socket)}
  end

  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    {:noreply, assign_request_state(socket)}
  end

  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, assign_available_series(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
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
  def render(%{live_action: :person} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Discover")}
      </.link>

      <div class="mb-8 flex gap-4">
        <img
          :if={@info.profile_path}
          src={poster_url(@info.profile_path)}
          alt={@info.name}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div class="min-w-0 flex-1">
          <.header>
            {@info.name}
            <:subtitle :if={@info.department}>{department_label(@info.department)}</:subtitle>
          </.header>
        </div>
      </div>

      <p :if={@info.total_credits > 60} class="mb-4 text-sm text-base-content/60">
        {gettext("Showing top 60 of %{total}", total: @info.total_credits)}
      </p>

      <.empty_state
        :if={@info.credits == []}
        icon="hero-user"
        title={gettext("No credits found")}
        message={gettext("TMDB returned no movie or TV credits for this person.")}
      />

      <.media_grid
        :if={@info.credits != []}
        id="credits"
        results={@info.credits}
        request_status={@request_status}
        movie_status={@movie_status}
        series_request_status={@series_request_status}
        available_series={@available_series}
      />
    </Layouts.app>
    """
  end

  def render(%{live_action: :collection} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Discover")}
      </.link>

      <div class="mb-8 flex gap-4">
        <img
          :if={@info.poster_path}
          src={poster_url(@info.poster_path)}
          alt={@info.title}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div class="min-w-0 flex-1">
          <.header>{@info.title}</.header>
        </div>
      </div>

      <.empty_state
        :if={@info.parts == []}
        icon="hero-rectangle-stack"
        title={gettext("No movies found")}
        message={gettext("TMDB returned no movies for this collection.")}
      />

      <.media_grid
        :if={@info.parts != []}
        id="parts"
        results={@info.parts}
        request_status={@request_status}
        movie_status={@movie_status}
        series_request_status={@series_request_status}
        available_series={@available_series}
      />
    </Layouts.app>
    """
  end
end
