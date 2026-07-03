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

  alias Cinder.{Catalog, Health, Requests}

  @parked [:no_match, :search_failed, :import_failed]
  @pipeline [:requested, :searching, :downloading, :downloaded, :upgrading]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      Requests.subscribe()
    end

    {:ok, socket |> assign(health: :loading, denying: nil) |> load() |> check_health()}
  end

  # Re-load on any pipeline/request change so stats, the queue, and recent activity stay live.
  # Every message this view receives rides the movies/series/requests topics it subscribes to,
  # so a single reload catch-all covers them all (mirrors MyRequestsLive).
  @impl true
  def handle_info(_msg, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_async(:health, {:ok, results}, socket),
    do: {:noreply, assign(socket, health: results)}

  def handle_async(:health, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, health: [%{label: gettext("Health check"), status: {:error, reason}}])}

  @impl true
  def handle_event("recheck_health", _params, socket),
    do: {:noreply, socket |> cancel_async(:health) |> assign(health: :loading) |> check_health()}

  def handle_event("approve", %{"id" => id}, socket) do
    req = find_pending(socket, id)

    case req && Requests.approve_request(req, socket.assigns.current_scope.user) do
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't approve that request."))}

      _ ->
        {:noreply, socket}
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
                    {if r.target_type == "season",
                      do:
                        gettext("%{title}: Season %{number}",
                          title: r.title,
                          number: r.season_number
                        ),
                      else: r.title}
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
                <.status_badge kind={:movie} status={m.status} />
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
