defmodule CinderWeb.SeriesDiscoveryLive do
  @moduledoc """
  User-facing series discovery at `/series/tmdb/:tmdb_id`.

  Loads season data directly from TMDB (no local series row required) and lets
  any authenticated user request a season. State badges (Pending / Approved /
  Denied) mirror the movie request-button pattern in `DiscoverLive`. No monitor
  toggles — those stay on the admin `/series/:id` page.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Requests

  @picks Language.preferences()

  @impl true
  def mount(%{"tmdb_id" => raw}, _session, socket) do
    # The :tmdb_id param is client-controlled; a non-integer must not crash the page.
    locale = socket.assigns.locale

    with {tmdb_id, ""} <- Integer.parse(raw),
         {:ok, info} <- Catalog.tmdb_series(tmdb_id, locale: locale) do
      info = Catalog.localize(info, locale)

      if connected?(socket) do
        Requests.subscribe()
        # Season availability derives from episode imports, which broadcast on "series".
        Catalog.subscribe_series()
      end

      user = socket.assigns.current_scope.user

      {:ok,
       socket
       |> assign(
         tmdb_id: tmdb_id,
         info: info,
         current_user: user,
         preferred_language: "original",
         proposed_media_profile: nil
       )
       |> assign(seasons: Enum.filter(info.seasons, &(&1.season_number != 0)))
       |> assign_requests_by_season(user, tmdb_id)}
    else
      # A TMDB outage is not "not found" — telling the user the series doesn't exist
      # sends them away from a title that loads fine once TMDB is back.
      {:error, reason} when reason != {:tmdb_status, 404} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Couldn't reach TMDB. Please try again in a moment."))
         |> push_navigate(to: ~p"/")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Series not found."))
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("request_season", %{"season" => raw}, socket) do
    with {season_number, ""} <- Integer.parse(raw),
         # Reject a season not in the show (prevents orphan-series rows). Validated
         # against @seasons — the requestable set, excluding Specials — so a forged
         # event can't create a dangling, never-grabbable season-0 request.
         true <- Enum.any?(socket.assigns.seasons, &(&1.season_number == season_number)) do
      info = socket.assigns.info
      user = socket.assigns.current_user

      attrs = %{
        target_type: "season",
        target_id: socket.assigns.tmdb_id,
        season_number: season_number,
        title: info.title,
        year: info.year,
        poster_path: info.poster_path,
        original_language: info[:original_language],
        preferred_language: socket.assigns.preferred_language,
        proposed_media_profile: socket.assigns.proposed_media_profile
      }

      # An admin/auto-approve request runs the season approval inline — seconds of TMDB I/O
      # (1 + N season fetches) — so it must not run in the event handler: the whole LiveView
      # would freeze (queued clicks, no flash) for the duration. Same pattern as /requests.
      {:noreply,
       start_async(socket, {:request_season, season_number}, fn ->
         Requests.create_request(user, attrs)
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_language", %{"preferred_language" => lang}, socket)
      when lang in @picks do
    {:noreply, assign(socket, :preferred_language, lang)}
  end

  def handle_event("set_profile", %{"proposed_media_profile" => profile}, socket)
      when profile in ["auto", "standard", "anime"] do
    profile = if profile == "auto", do: nil, else: String.to_existing_atom(profile)
    {:noreply, assign(socket, :proposed_media_profile, profile)}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:request_season, season_number}, {:ok, result}, socket) do
    info = socket.assigns.info

    case result do
      {:ok, %{status: :approved}} ->
        socket
        |> put_flash(
          :info,
          gettext("Season %{number} of %{title} added.",
            number: season_number,
            title: info.title
          )
        )
        |> refresh_requests()
        |> then(&{:noreply, &1})

      {:ok, %{status: :pending}} ->
        socket
        |> put_flash(
          :info,
          gettext("Season %{number} of %{title} requested. Awaiting approval.",
            number: season_number,
            title: info.title
          )
        )
        |> refresh_requests()
        |> then(&{:noreply, &1})

      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You've reached your request limit. Wait for approvals to clear.")
         )}

      # Only the duplicate-pending unique constraint means "already requested"; any
      # other changeset failure is a real error, not a reassuring info toast.
      {:error, %Ecto.Changeset{} = cs} ->
        if duplicate_request?(cs) do
          {:noreply,
           put_flash(
             socket,
             :info,
             gettext("Season %{number} is already requested.", number: season_number)
           )}
        else
          {:noreply, request_error(socket)}
        end

      {:error, _} ->
        {:noreply, request_error(socket)}
    end
  end

  def handle_async({:request_season, _season_number}, {:exit, _reason}, socket) do
    {:noreply, request_error(socket)}
  end

  defp request_error(socket),
    do: put_flash(socket, :error, gettext("Couldn't complete that request. Please try again."))

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    {:noreply, refresh_requests(socket)}
  end

  # Episode imports ride the "series" topic; a season completing flips its badge live.
  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, refresh_requests(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_requests(socket) do
    assign_requests_by_season(socket, socket.assigns.current_user, socket.assigns.tmdb_id)
  end

  defp assign_requests_by_season(socket, user, tmdb_id) do
    # Bug A: list_for_user returns desc id (newest first); Map.put_new keeps the first
    # seen value per key, so the newest request status wins over any older ones.
    requests_by_season =
      user
      |> Requests.list_for_user()
      |> Enum.filter(&(&1.target_type == "season" and &1.target_id == tmdb_id))
      |> latest_status_by(& &1.season_number)

    # Availability outranks a stale request status (mirrors the movie title_state
    # precedence): a fully imported season must not read "Denied" with a re-Request button.
    available = MapSet.new(Catalog.available_season_keys(tmdb_id), fn {_tid, n} -> n end)

    assign(socket, requests_by_season: requests_by_season, available_seasons: available)
  end

  @impl true
  def render(assigns) do
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
          <.header>
            {@info.title}
            <span :if={@info.year} class="font-normal text-base-content/70">({@info.year})</span>
          </.header>
        </div>
      </div>

      <form id="series-language-form" phx-change="set_language" class="mb-4 max-w-xs">
        <.language_select value={@preferred_language} />
      </form>
      <form id="series-profile-form" phx-change="set_profile" class="mb-4 max-w-xs">
        <.media_profile_select value={@proposed_media_profile} />
      </form>

      <%!-- @seasons excludes Specials (season 0, not requestable), so a specials-only
            series gets this empty state instead of a blank page with nothing to do. --%>
      <.empty_state
        :if={@seasons == []}
        icon="hero-tv"
        title={gettext("No requestable seasons")}
        message={
          if @info.seasons == [],
            do: gettext("TMDB returned no season data for this series."),
            else: gettext("This series only has specials, which can't be requested yet.")
        }
      />

      <ul class="divide-y divide-base-200">
        <li
          :for={season <- @seasons}
          class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 py-3"
        >
          <span class="font-medium">{season_label(season.season_number)}</span>
          <.season_action
            season_number={season.season_number}
            status={
              if MapSet.member?(@available_seasons, season.season_number),
                do: :available,
                else: @requests_by_season[season.season_number]
            }
          />
        </li>
      </ul>
    </Layouts.app>
    """
  end

  attr :season_number, :integer, required: true
  attr :status, :atom, default: nil

  defp season_action(assigns) do
    ~H"""
    <.status_badge :if={@status != nil} kind={:request} status={@status} />
    <.button
      :if={@status in [nil, :denied]}
      type="button"
      phx-click="request_season"
      phx-value-season={@season_number}
      phx-disable-with={gettext("Requesting…")}
      variant="primary"
      size="sm"
    >
      {gettext("Request")}
    </.button>
    """
  end
end
