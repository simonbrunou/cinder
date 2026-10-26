defmodule CinderWeb.SeriesDiscoveryLive do
  @moduledoc """
  User-facing series discovery at `/series/tmdb/:tmdb_id`.

  Loads season data directly from TMDB (no local series row required) and lets
  any authenticated user request a season. State badges (Pending / Approved /
  Denied) mirror the movie request-button pattern in `DiscoverLive`. A season already in the
  library — fully imported by Cinder, or held by the media server even for a show Cinder never
  added — reads Available instead of offering Request; a partly present one shows its episode
  count. No monitor toggles — those stay on the admin `/series/:id` page.
  """
  use CinderWeb, :live_view

  import CinderWeb.DiscoverComponents
  import CinderWeb.LiveHelpers
  import CinderWeb.RequestHelpers, only: [assign_request_state: 1, normalize_profile: 2]

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Catalog.MediaServerSeasons
  alias Cinder.Requests
  alias Cinder.Requests.Target
  alias Cinder.Settings

  require Logger

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
         proposed_profile: nil,
         tv_profiles: Catalog.list_profiles(:tv),
         movie_profiles: Catalog.list_profiles(:movies),
         recommendations: []
       )
       |> assign(seasons: Enum.filter(info.seasons, &(&1.season_number != 0)))
       |> refresh_requests()
       |> assign_media_server()
       |> assign_request_state()
       |> maybe_load_recommendations()}
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
  def handle_event("request_season", %{"season" => raw}, socket) when is_binary(raw) do
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

  def handle_event("set_profile", %{"proposed_profile_id" => raw}, socket) do
    case normalize_profile(raw, :tv) do
      {:ok, profile} -> {:noreply, assign(socket, :proposed_profile, profile)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("set_profile", %{"proposed_media_profile" => raw}, socket) do
    handle_event("set_profile", %{"proposed_profile_id" => raw}, socket)
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
           gettext("You've reached your request limit. Wait for an earlier request to finish.")
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

  def handle_async(:recommendations, {:ok, {:ok, results}}, socket) do
    # Drop this series from its own recommendations (defensive).
    results = Enum.reject(results, &(&1.tmdb_id == socket.assigns.tmdb_id))
    {:noreply, assign(socket, :recommendations, results)}
  end

  # The rail is decorative — on failure the page simply stays rail-less, no flash.
  def handle_async(:recommendations, {:ok, {:error, reason}}, socket) do
    Logger.warning("Series recommendations fetch failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:recommendations, {:exit, reason}, socket) do
    Logger.warning("Series recommendations fetch crashed: #{inspect(reason)}")
    {:noreply, socket}
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
          gettext("You've reached your request limit. Wait for an earlier request to finish.")
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
    # refresh_requests drives the season list; assign_request_state keeps the "More like this"
    # rail's per-title badges live too.
    {:noreply, socket |> refresh_requests() |> assign_request_state()}
  end

  # Episode imports ride the "series" topic, as does a changed media-server season inventory;
  # either can flip a season's badge live.
  def handle_info({event, _id}, socket) when event in [:series_updated, :series_deleted] do
    {:noreply, refresh_availability(socket)}
  end

  def handle_info(:media_server_seasons_updated, socket) do
    {:noreply, refresh_availability(socket)}
  end

  # An admin switching media-server type/URL must not leave an open page linking at the old one,
  # or counting the seasons only the old type held.
  def handle_info(:settings_updated, socket) do
    {:noreply, refresh_availability(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_availability(socket) do
    socket |> refresh_requests() |> assign_request_state() |> assign_media_server()
  end

  # A show Cinder never added has no reconciled series row, but its media-server season
  # inventory still names the show's item, so the link deep-links there too.
  defp assign_media_server(socket) do
    item_id =
      case Catalog.get_series_by_tmdb_id(socket.assigns.tmdb_id) do
        %{media_server_item_id: id} when is_binary(id) -> id
        _ -> socket.assigns.server_item_id
      end

    case Settings.media_server_web_link(item_id) do
      {server, url} -> assign(socket, media_server_url: url, media_server_name: name(server))
      nil -> assign(socket, media_server_url: nil, media_server_name: nil)
    end
  end

  # Product names, deliberately not gettext'd.
  defp name(:plex), do: "Plex"
  defp name(:jellyfin), do: "Jellyfin"

  # The "More like this" rail is fetched off-process on the connected mount (one call, not two)
  # so a slow TMDB can't hold up render; a failure leaves the page rail-less (see handle_async).
  defp maybe_load_recommendations(socket) do
    if connected?(socket) do
      %{tmdb_id: tmdb_id, locale: locale} = socket.assigns
      start_async(socket, :recommendations, fn -> Catalog.recommended_tv(tmdb_id, locale) end)
    else
      socket
    end
  end

  defp refresh_requests(socket) do
    socket
    |> assign_requests_by_season(socket.assigns.current_user, socket.assigns.tmdb_id)
    |> assign_availability()
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
      proposed_profile_id: socket.assigns.proposed_profile && socket.assigns.proposed_profile.id,
      proposed_media_profile:
        socket.assigns.proposed_profile && socket.assigns.proposed_profile.handling
    }
  end

  # The seasons a bulk "Request all" should touch: exactly those still showing a per-season
  # Request button. Season 0 is already excluded from @seasons upstream.
  defp requestable_season_numbers(%{
         seasons: seasons,
         season_availability: availability,
         requests_by_season: requests_by_season
       }) do
    for %{season_number: n} <- seasons,
        season_status(availability, requests_by_season, n) in [nil, :denied],
        do: n
  end

  # Availability outranks a stale request status (mirrors the movie title_state precedence): a
  # season already in the library must not read "Denied" with a re-Request button.
  defp season_status(availability, requests_by_season, season_number) do
    case availability[season_number] do
      :available -> :available
      _ -> requests_by_season[season_number]
    end
  end

  defp assign_requests_by_season(socket, user, tmdb_id) do
    # Bug A: list_for_user returns desc id (newest first); Map.put_new keeps the first
    # seen value per key, so the newest request status wins over any older ones.
    requests_by_season =
      user
      |> Requests.list_for_user()
      |> Enum.filter(&match?({:season, ^tmdb_id, _n}, Target.key(&1)))
      |> latest_status_by(& &1.season_number)

    assign(socket, requests_by_season: requests_by_season)
  end

  # One verdict per season, from Cinder's own episodes and the media server's inventory alike, so
  # a season already on Plex/Jellyfin reads as available even for a show Cinder never added.
  # `:available` once Cinder has fully landed the season or the server holds at least as many
  # episodes as TMDB lists; `{:partial, have, total}` while either side holds some of it (the
  # Request button stays); absent otherwise.
  defp assign_availability(socket) do
    %{tmdb_id: tmdb_id, seasons: seasons} = socket.assigns
    landed = MapSet.new(Catalog.available_season_keys(tmdb_id), fn {_tid, n} -> n end)
    progress = Catalog.season_progress_keys(tmdb_id)
    server = MediaServerSeasons.for_series(tmdb_id)
    on_server = Map.new(server, &{&1.season_number, &1.episode_count})

    availability =
      for %{season_number: n} = season <- seasons,
          state =
            season_availability(
              MapSet.member?(landed, n),
              progress[{tmdb_id, n}],
              on_server[n],
              season[:episode_count]
            ),
          state != nil,
          into: %{},
          do: {n, state}

    assign(socket,
      season_availability: availability,
      server_item_id: Enum.find_value(server, & &1.item_id)
    )
  end

  defp season_availability(true, _progress, _on_server, _tmdb_total), do: :available

  defp season_availability(false, progress, on_server, tmdb_total) do
    on_server = on_server || 0
    %{available: imported, total: cinder_total} = progress || %{available: 0, total: nil}
    have = max(imported, on_server)

    cond do
      server_complete?(on_server, tmdb_total) -> :available
      have > 0 -> {:partial, have, tmdb_total || cinder_total}
      true -> nil
    end
  end

  defp server_complete?(on_server, tmdb_total) when is_integer(tmdb_total) and tmdb_total > 0,
    do: on_server >= tmdb_total

  defp server_complete?(_on_server, _tmdb_total), do: false

  defp partial_hint({:partial, have, total}) when is_integer(total) and total > 0,
    do:
      ngettext(
        "%{available} of %{count} episode available",
        "%{available} of %{count} episodes available",
        total,
        available: have
      )

  defp partial_hint({:partial, have, _total}),
    do: ngettext("%{count} episode available", "%{count} episodes available", have)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.link navigate={~p"/"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Discover")}
      </.link>

      <div class="mb-8 flex flex-col gap-6 sm:flex-row">
        <.detail_poster poster_path={@info.poster_path} title={media_title(@info, @locale)} />

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

          <%!-- Exact reconciled items deep-link to this series; unmatched items retain the server
                front door. --%>
          <.button
            :if={@media_server_url && @season_availability != %{}}
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
        <.media_profile_select
          value={@proposed_profile && @proposed_profile.id}
          profiles={@tv_profiles}
        />
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
          <div class="flex flex-col">
            <span class="font-medium">{season_label(season.season_number)}</span>
            <span
              :if={match?({:partial, _, _}, @season_availability[season.season_number])}
              id={"seriesdiscovery-season-progress-#{season.season_number}"}
              class="text-sm text-base-content/70"
            >
              {partial_hint(@season_availability[season.season_number])}
            </span>
          </div>
          <.season_action
            season_number={season.season_number}
            status={season_status(@season_availability, @requests_by_season, season.season_number)}
          />
        </li>
      </ul>

      <.cast_strip cast={@info[:cast] || []} />

      <.more_like_this
        id="series-recommendations"
        results={@recommendations}
        request_status={@request_status}
        movie_status={@movie_status}
        series_request_status={@series_request_status}
        available_series={@available_series}
        movie_profiles={@movie_profiles}
      />
    </Layouts.app>
    """
  end

  attr :season_number, :integer, required: true
  attr :status, :atom, default: nil

  defp season_action(assigns) do
    ~H"""
    <.status_badge
      :if={@status != nil}
      id={"seriesdiscovery-season-status-#{@season_number}"}
      kind={:request}
      status={@status}
    />
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
