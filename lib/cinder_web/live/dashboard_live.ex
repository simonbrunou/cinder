defmodule CinderWeb.DashboardLive do
  @moduledoc """
  Admin landing at `/dashboard`: pipeline stats at a glance, an inline pending-approval
  queue (approve / deny), service health, and a compact recent-activity slice. Read-mostly;
  approve/deny route through `Cinder.Requests` exactly as `/requests` does — no new gate.
  Live via the `movies` + `series` + `requests` topics; health runs in a `start_async` task
  so a slow service can't block render.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.{Catalog, Health, Library, Notifier, Requests}
  alias Cinder.Catalog.Refresher
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Subtitles.Sweeper

  require Logger

  @parked [:no_match, :search_failed, :import_failed]
  @pipeline [:requested, :searching, :downloading, :downloaded, :upgrading]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      Requests.subscribe()
    end

    {:ok,
     socket
     |> assign(
       health: :loading,
       denying: nil,
       maintenance_actions: maintenance_actions(),
       running_maintenance: [],
       maintenance_results: %{}
     )
     |> load()
     |> check_health()}
  end

  # Re-load on any pipeline/request change so stats, the queue, and recent activity stay live.
  # Every message this view receives rides the movies/series/requests topics it subscribes to,
  # so a single reload catch-all covers them all (mirrors MyRequestsLive).
  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_async(:health, {:ok, results}, socket),
    do: {:noreply, assign(socket, health: results)}

  def handle_async({:approve, _id}, {:ok, {:ok, _req}}, socket), do: {:noreply, socket}

  # A stale double-click: the first approval already committed — don't say "try again".
  def handle_async({:approve, _id}, {:ok, {:error, :not_pending}}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("That request was already decided."))}

  def handle_async({:approve, _id}, _error_or_exit, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Couldn't approve that request."))}

  def handle_async(:health, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, health: [%{label: gettext("Health check"), status: {:error, reason}}])}

  def handle_async({:maintenance, key}, {:ok, :ok}, socket) do
    Notifier.notify({:maintenance_completed, key})
    {:noreply, finish_maintenance(socket, key, :ok)}
  end

  def handle_async({:maintenance, key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, maintenance_failed(socket, key, reason)}

  def handle_async({:maintenance, key}, {:exit, reason}, socket),
    do: {:noreply, maintenance_failed(socket, key, reason)}

  @impl true
  def handle_event("recheck_health", _params, socket),
    do: {:noreply, socket |> cancel_async(:health) |> assign(health: :loading) |> check_health()}

  def handle_event("approve", %{"id" => id}, socket) do
    case find_pending(socket, id) do
      nil ->
        {:noreply, socket}

      req ->
        # A season approval does blocking TMDB I/O (1 + N season fetches) — run it off the
        # LiveView (matching /requests) so a single click can't freeze the page for seconds.
        # Keyed per request so overlapping approvals don't overwrite each other's results.
        admin = socket.assigns.current_scope.user
        profile = req.proposed_media_profile || :standard

        {:noreply,
         start_async(socket, {:approve, req.id}, fn ->
           Requests.approve_request(req, admin, profile)
         end)}
    end
  end

  def handle_event("start_deny", %{"id" => id}, socket),
    do: {:noreply, assign(socket, denying: id)}

  def handle_event("dismiss_deny", _params, socket),
    do: {:noreply, assign(socket, denying: nil)}

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    req = find_pending(socket, id)

    case req && Requests.deny_request(req, socket.assigns.current_scope.user, reason) do
      {:error, _} ->
        {:noreply,
         socket
         |> assign(denying: nil)
         |> put_flash(:error, gettext("Couldn't deny that request."))}

      _ ->
        {:noreply, assign(socket, denying: nil)}
    end
  end

  def handle_event("run_maintenance", %{"action" => id}, socket) do
    case Enum.find(socket.assigns.maintenance_actions, &(&1.id == id)) do
      %{key: key} ->
        if key in socket.assigns.running_maintenance do
          {:noreply, socket}
        else
          {:noreply,
           socket
           |> assign(:running_maintenance, [key | socket.assigns.running_maintenance])
           |> assign(:maintenance_results, Map.delete(socket.assigns.maintenance_results, key))
           |> start_async({:maintenance, key}, fn -> run_maintenance(key) end)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp find_pending(socket, id), do: find_by_id(socket.assigns.pending, id)

  # Runs on every pipeline/request broadcast, so it leans on count/limit queries (a grouped
  # status count + a LIMIT-8 recent slice + a few COUNT(*)s) rather than loading whole tables
  # just to take their length — stays cheap as the catalog grows.
  defp load(socket) do
    counts = Catalog.movie_status_counts()

    assign(socket,
      pending: Requests.list_pending(),
      recent: Catalog.recent_movies(8),
      stats: %{
        movies_total: counts |> Map.values() |> Enum.sum(),
        movies_available: Map.get(counts, :available, 0),
        in_pipeline: Enum.sum(Enum.map(@pipeline, &Map.get(counts, &1, 0))),
        parked: Enum.sum(Enum.map(@parked, &Map.get(counts, &1, 0))),
        series_total: Catalog.count_series(),
        tv_wanted: Catalog.count_wanted_episodes(),
        downloading: Catalog.count_grabs_downloading()
      }
    )
  end

  defp check_health(socket) do
    if connected?(socket),
      do: start_async(socket, :health, &Health.check_all/0),
      else: socket
  end

  defp maintenance_actions do
    [
      %{
        id: "movie-pipeline",
        key: :movie_pipeline,
        label: gettext("Movie pipeline"),
        description: gettext("Advance movie searches, downloads, imports, and upgrades.")
      },
      %{
        id: "tv-pipeline",
        key: :tv_pipeline,
        label: gettext("TV pipeline"),
        description: gettext("Advance monitored TV searches, downloads, and imports.")
      },
      %{
        id: "series-refresh",
        key: :series_refresh,
        label: gettext("Monitored series refresh"),
        description: gettext("Reconcile monitored series and episodes with TMDB.")
      },
      %{
        id: "subtitle-backfill",
        key: :subtitle_backfill,
        label: gettext("Subtitle backfill"),
        description: gettext("Find missing subtitles for imported movies and episodes.")
      },
      %{
        id: "scan-movies",
        key: :scan_movies,
        label: gettext("Movie library scan"),
        description: gettext("Request a movie-library refresh from the media server.")
      },
      %{
        id: "scan-tv",
        key: :scan_tv,
        label: gettext("TV library scan"),
        description: gettext("Request a TV-library refresh from the media server.")
      }
    ]
  end

  defp run_maintenance(:movie_pipeline), do: Poller.poll()
  defp run_maintenance(:tv_pipeline), do: TvPoller.poll()
  defp run_maintenance(:series_refresh), do: Refresher.poll()
  defp run_maintenance(:subtitle_backfill), do: Sweeper.poll()
  defp run_maintenance(:scan_movies), do: Library.scan(:movies)
  defp run_maintenance(:scan_tv), do: Library.scan(:tv)

  defp finish_maintenance(socket, key, result) do
    socket
    |> assign(:running_maintenance, List.delete(socket.assigns.running_maintenance, key))
    |> assign(:maintenance_results, Map.put(socket.assigns.maintenance_results, key, result))
  end

  defp maintenance_failed(socket, key, reason) do
    Logger.warning("maintenance #{key} failed: #{inspect(reason)}")
    Notifier.notify({:maintenance_failed, key, reason})
    finish_maintenance(socket, key, :error)
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :suffix, :any, default: nil
  attr :icon, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="flex items-baseline gap-2">
      <.icon name={@icon} class="size-4 shrink-0 self-center text-base-content/70" />
      <span class="text-lg font-semibold tabular-nums">{@value}</span>
      <span class="text-sm text-base-content/70">{@label}</span>
      <span :if={@suffix} class="text-xs text-base-content/70">· {@suffix}</span>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Dashboard")}
        <:subtitle>{gettext("Pipeline at a glance.")}</:subtitle>
      </.header>

      <div class="flex flex-col gap-3 rounded-box border border-base-300 bg-base-200/50 p-4 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-8">
        <.stat_card
          label={gettext("Movies available")}
          value={@stats.movies_available}
          suffix={gettext("of %{count} total", count: @stats.movies_total)}
          icon="hero-film"
        />
        <.stat_card
          label={gettext("In pipeline")}
          value={@stats.in_pipeline}
          suffix={@stats.parked > 0 && gettext("%{count} parked", count: @stats.parked)}
          icon="hero-arrow-path"
        />
        <.stat_card
          label={gettext("TV wanted")}
          value={@stats.tv_wanted}
          suffix={gettext("%{count} series", count: @stats.series_total)}
          icon="hero-tv"
        />
        <.stat_card
          label={gettext("Pending requests")}
          value={length(@pending)}
          suffix={
            @stats.downloading > 0 && gettext("%{count} downloading", count: @stats.downloading)
          }
          icon="hero-inbox-arrow-down"
        />
      </div>

      <section class="mt-8">
        <div class="mb-3">
          <h2 class="text-lg font-semibold">{gettext("Run maintenance")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("Run a background pass now without changing its schedule.")}
          </p>
        </div>
        <ul class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <li
            :for={action <- @maintenance_actions}
            class="flex items-center justify-between gap-4 rounded-box border border-base-300 bg-base-200/50 p-4"
          >
            <div class="min-w-0">
              <p class="font-medium">{action.label}</p>
              <p class="text-sm text-base-content/70">{action.description}</p>
              <p
                :if={Map.get(@maintenance_results, action.key)}
                id={"maintenance-result-#{action.id}"}
                role="status"
                aria-live="polite"
                class={[
                  "mt-1 text-xs font-medium",
                  Map.get(@maintenance_results, action.key) == :ok && "text-success",
                  Map.get(@maintenance_results, action.key) == :error && "text-error"
                ]}
              >
                {if Map.get(@maintenance_results, action.key) == :ok,
                  do: gettext("Completed"),
                  else: gettext("Failed")}
              </p>
            </div>
            <.button
              id={"maintenance-#{action.id}"}
              variant="neutral"
              size="sm"
              phx-click="run_maintenance"
              phx-value-action={action.id}
              disabled={action.key in @running_maintenance}
              aria-label={
                if action.key in @running_maintenance,
                  do: gettext("Running %{action}", action: action.label),
                  else: gettext("Run %{action}", action: action.label)
              }
            >
              {if action.key in @running_maintenance, do: gettext("Running…"), else: gettext("Run")}
            </.button>
          </li>
        </ul>
      </section>

      <div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section>
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-lg font-semibold">{gettext("Pending approvals")}</h2>
            <.link
              navigate={~p"/requests"}
              class="link link-hover inline-flex items-center gap-1 text-sm"
            >
              {gettext("All requests")}<.icon name="hero-arrow-right" class="size-3.5" />
            </.link>
          </div>
          <.empty_state
            :if={@pending == []}
            icon="hero-check-circle"
            title={gettext("Nothing to approve")}
            message={gettext("New requests appear here.")}
          />
          <ul :if={@pending != []} class="space-y-3">
            <li :for={r <- @pending} id={"pending-#{r.id}"} class="rounded-box bg-base-200/50 p-4">
              <div class="flex flex-row items-center gap-4">
                <img
                  :if={r.poster_path}
                  src={poster_url(r.poster_path, "w92")}
                  alt={r.title}
                  loading="lazy"
                  decoding="async"
                  class="w-12 rounded"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-medium">
                    {request_title(r)}
                    <span :if={r.year} class="text-base-content/70">({r.year})</span>
                  </p>
                  <p class="truncate text-sm text-base-content/70">{r.user.email}</p>
                </div>
                <.status_badge kind={:request} status={r.status} />
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <.button
                  variant="primary"
                  size="sm"
                  phx-click="approve"
                  phx-value-id={r.id}
                  phx-disable-with={gettext("Approving…")}
                >
                  {gettext("Approve")}
                </.button>
                <.button
                  :if={@denying != to_string(r.id)}
                  variant="ghost"
                  size="sm"
                  phx-click="start_deny"
                  phx-value-id={r.id}
                >
                  {gettext("Deny")}
                </.button>
                <.deny_form
                  :if={@denying == to_string(r.id)}
                  event="deny"
                  id={r.id}
                  reason_label={gettext("Denial reason")}
                  submit_label={gettext("Confirm deny")}
                  on_cancel="dismiss_deny"
                  class="flex-1"
                />
              </div>
            </li>
          </ul>
        </section>

        <div class="space-y-6">
          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{gettext("Service health")}</h2>
              <.button
                variant="ghost"
                size="sm"
                phx-click="recheck_health"
                phx-disable-with={gettext("Checking…")}
                aria-label={gettext("Recheck service health")}
              >
                {gettext("Recheck")}
              </.button>
            </div>
            <.spinner :if={@health == :loading} label={gettext("Checking services…")} />
            <ul
              :if={@health != :loading}
              id="dashboard-health"
              class="w-full divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-200"
            >
              <li :for={h <- @health} class="flex items-center justify-between gap-3 px-4 py-2.5">
                <div class="min-w-0">
                  <span>{h.label}</span>
                  <p :if={match?({:error, _}, h.status)} class="text-xs text-error break-words">
                    {health_reason(elem(h.status, 1))}
                  </p>
                </div>
                <.status_badge kind={:health} status={h.status} />
              </li>
            </ul>
          </section>

          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{gettext("Recent activity")}</h2>
              <.link
                navigate={~p"/activity"}
                class="link link-hover inline-flex items-center gap-1 text-sm"
              >
                {gettext("View all")}<.icon name="hero-arrow-right" class="size-3.5" />
              </.link>
            </div>
            <.empty_state
              :if={@recent == []}
              icon="hero-film"
              title={gettext("No activity yet")}
              message={gettext("Request a movie to get started.")}
            />
            <ul :if={@recent != []} class="space-y-2">
              <li :for={m <- @recent} class="flex items-center gap-3">
                <.status_badge
                  kind={:movie}
                  status={m.status}
                  progress={m.download_progress}
                  speed={m.download_speed}
                  eta={m.download_eta}
                />
                <span class="truncate">{m.title}</span>
                <span :if={m.year} class="text-sm text-base-content/70">({m.year})</span>
                <time
                  datetime={DateTime.to_iso8601(m.updated_at)}
                  class="ml-auto whitespace-nowrap text-xs text-base-content/70"
                >
                  {format_date(m.updated_at)}
                </time>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
