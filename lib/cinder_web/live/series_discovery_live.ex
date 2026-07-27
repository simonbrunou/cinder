defmodule CinderWeb.SeriesDiscoveryLive do
  @moduledoc """
  User-facing series discovery at `/series/tmdb/:tmdb_id`.

  Loads season data directly from TMDB (no local series row required) and lets
  any authenticated user request a season. State badges (Pending / Approved /
  Denied) mirror the movie request-button pattern in `DiscoverLive`. No monitor
  toggles — those stay on the admin `/series/:id` page.
  """
  use CinderWeb, :live_view

  import CinderWeb.DiscoverComponents
  import CinderWeb.LiveHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Requests
  alias Cinder.Settings

  @picks Language.preferences()

  @impl true
  def mount(%{"tmdb_id" => raw}, _session, socket) do
    # The :tmdb_id param is client-controlled; a non-integer must not crash the page.
    with {tmdb_id, ""} <- Integer.parse(raw),
         {:ok, info} <- Catalog.tmdb_series(tmdb_id) do
      if connected?(socket) do
        Requests.subscribe()
        # Season availability derives from episode imports, which broadcast on "series".
        Catalog.subscribe_series()
        # Keep the "Open in <media server>" link fresh if an admin changes the server type/URL.
        Settings.subscribe()
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
       |> assign_media_server()
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
      user = socket.assigns.current_user
      attrs = season_attrs(socket, season_number)

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

  # Fan a single click out to one request per not-yet-requested season, reusing the same
  # per-season `Requests.create_request` path (quota + approval gate intact) rather than a
  # bulk-request model. The requestable set is derived server-side from validated assigns —
  # nothing is taken from the event payload — so there is no forgeable season list to parse.
  def handle_event("request_all_seasons", _params, socket) do
    case requestable_season_numbers(socket.assigns) do
      [] ->
        {:noreply,
         put_flash(socket, :info, gettext("Every season is already requested or available."))}

      numbers ->
        user = socket.assigns.current_user
        attrs_list = Enum.map(numbers, &season_attrs(socket, &1))

        {:noreply,
         start_async(socket, :request_all_seasons, fn -> fan_out_seasons(user, attrs_list) end)}
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
    title = media_title(socket.assigns.info, socket.assigns.locale)

    case result do
      {:ok, %{status: :approved}} ->
        socket
        |> put_flash(
          :info,
          gettext("Season %{number} of %{title} added.",
            number: season_number,
            title: title
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
            title: title
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

  def handle_async(:request_all_seasons, {:ok, summary}, socket) do
    title = media_title(socket.assigns.info, socket.assigns.locale)

    {:noreply,
     socket
     |> fan_out_flash(title, summary)
     |> refresh_requests()}
  end

  def handle_async(:request_all_seasons, {:exit, _reason}, socket) do
    {:noreply, request_error(socket)}
  end

  defp request_error(socket),
    do: put_flash(socket, :error, gettext("Couldn't complete that request. Please try again."))

  # Sequentially request each season, stopping the moment the per-user quota is hit — the
  # remaining seasons are left un-submitted, and the count is reported to the user. A
  # non-quota failure (e.g. a duplicate from a concurrent click) is counted and skipped.
  defp fan_out_seasons(user, attrs_list) do
    Enum.reduce_while(
      attrs_list,
      %{approved: 0, pending: 0, quota_stopped: false, total: length(attrs_list)},
      fn attrs, acc ->
        case Requests.create_request(user, attrs) do
          {:ok, %{status: :approved}} -> {:cont, %{acc | approved: acc.approved + 1}}
          {:ok, %{status: :pending}} -> {:cont, %{acc | pending: acc.pending + 1}}
          {:error, :quota_exceeded} -> {:halt, %{acc | quota_stopped: true}}
          {:error, _} -> {:cont, acc}
        end
      end
    )
  end

  defp fan_out_flash(socket, title, %{approved: approved, pending: pending} = summary) do
    submitted = approved + pending

    cond do
      submitted > 0 ->
        base = fan_out_success_message(pending, submitted, title)
        put_flash(socket, :info, base <> fan_out_tail(summary, summary.total - submitted))

      # Nothing landed and the quota was the blocker — say so specifically.
      summary.quota_stopped ->
        put_flash(
          socket,
          :error,
          gettext("You've reached your request limit. Wait for approvals to clear.")
        )

      # Nothing landed for some other reason (rare: e.g. all duplicated by a concurrent click).
      true ->
        request_error(socket)
    end
  end

  # In one fan-out a user is either an auto-approver (all approved) or not (all pending); a
  # non-zero pending count means the plain "requested, awaiting approval" copy fits.
  defp fan_out_success_message(0, n, title),
    do:
      ngettext(
        "Added %{count} season of %{title}.",
        "Added %{count} seasons of %{title}.",
        n,
        count: n,
        title: title
      )

  defp fan_out_success_message(_pending, n, title),
    do:
      ngettext(
        "Requested %{count} season of %{title}. Awaiting approval.",
        "Requested %{count} seasons of %{title}. Awaiting approval.",
        n,
        count: n,
        title: title
      )

  defp fan_out_tail(%{quota_stopped: true}, not_submitted),
    do:
      " " <>
        ngettext(
          "Stopped at your request limit; %{count} season not submitted.",
          "Stopped at your request limit; %{count} seasons not submitted.",
          not_submitted,
          count: not_submitted
        )

  defp fan_out_tail(_summary, _not_submitted), do: ""

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    {:noreply, refresh_requests(socket)}
  end

  # Episode imports ride the "series" topic; a season completing flips its badge live.
  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, refresh_requests(socket)}
  end

  # An admin switching media-server type/URL must not leave an open page linking at the old one.
  def handle_info(:settings_updated, socket) do
    {:noreply, assign_media_server(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Re-read on mount and on every settings write, mirroring MovieDiscoveryLive: an admin fixing
  # the media-server URL must not leave an already-open page pointing at the old server.
  defp assign_media_server(socket) do
    case Settings.media_server_web_link() do
      {server, url} -> assign(socket, media_server_url: url, media_server_name: name(server))
      nil -> assign(socket, media_server_url: nil, media_server_name: nil)
    end
  end

  # Product names, deliberately not gettext'd.
  defp name(:plex), do: "Plex"
  defp name(:jellyfin), do: "Jellyfin"

  defp refresh_requests(socket) do
    assign_requests_by_season(socket, socket.assigns.current_user, socket.assigns.tmdb_id)
  end

  defp season_attrs(socket, season_number) do
    info = socket.assigns.info

    %{
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
  end

  # The seasons a bulk "Request all" should touch: exactly those still showing a per-season
  # Request button (status nil or :denied), and not already available. Season 0 is already
  # excluded from @seasons upstream.
  defp requestable_season_numbers(assigns) do
    for season <- assigns.seasons,
        not MapSet.member?(assigns.available_seasons, season.season_number),
        Map.get(assigns.requests_by_season, season.season_number) in [nil, :denied],
        do: season.season_number
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
    >
      <.link navigate={~p"/"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Discover")}
      </.link>

      <div class="mb-8 flex flex-col gap-6 sm:flex-row">
        <img
          :if={@info.poster_path}
          src={poster_url(@info.poster_path)}
          alt={media_title(@info, @locale)}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-40 shrink-0 rounded object-cover"
        />
        <div
          :if={!@info.poster_path}
          class="grid aspect-[2/3] w-40 shrink-0 place-items-center rounded bg-base-300 text-sm text-base-content/70"
        >
          {gettext("No poster")}
        </div>

        <div class="min-w-0 flex-1">
          <.header>
            {media_title(@info, @locale)}
            <span :if={@info.year} class="font-normal text-base-content/70">({@info.year})</span>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@info[:first_air_date]} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@info.first_air_date)}
            </span>
            <span
              :if={is_number(@info[:vote_average]) and @info.vote_average > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-star" class="size-4" />{rating(@info.vote_average)}
            </span>
          </div>

          <div :if={@info[:genres] not in [nil, []]} class="mt-3 flex flex-wrap gap-1">
            <span :for={g <- @info.genres} class="badge badge-outline badge-sm">{g}</span>
          </div>

          <p :if={media_overview(@info, @locale)} class="mt-4 max-w-prose text-sm leading-relaxed">
            {media_overview(@info, @locale)}
          </p>
          <p :if={is_nil(media_overview(@info, @locale))} class="mt-4 text-sm text-base-content/50">
            {gettext("No description available.")}
          </p>

          <%!-- Opens the media server's front door (Cinder stores no per-title id), only once at
                least one season is in the library and an operator has set a browser URL — same
                affordance as the movie detail page. --%>
          <.button
            :if={@media_server_url && MapSet.size(@available_seasons) > 0}
            href={@media_server_url}
            target="_blank"
            rel="noopener"
            variant="primary"
            size="sm"
            class="mt-4"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />{gettext(
              "Open in %{server}",
              server: @media_server_name
            )}
            <span class="sr-only">{gettext("(opens in a new tab)")}</span>
          </.button>
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

      <div :if={requestable_season_numbers(assigns) != []} class="mb-4 flex justify-end">
        <.button
          type="button"
          phx-click="request_all_seasons"
          phx-disable-with={gettext("Requesting…")}
          aria-label={gettext("Request all not-yet-requested seasons")}
          variant="primary"
          size="sm"
        >
          {gettext("Request all seasons")}
        </.button>
      </div>

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

      <.cast_strip cast={@info[:cast] || []} />
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
