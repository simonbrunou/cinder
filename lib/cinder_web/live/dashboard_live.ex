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
  @pipeline [:requested, :searching, :downloading, :downloaded]

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

  # ponytail: derives counts + the recent slice from a single full-watchlist load and a few
  # length(list_*) reads — fine at single-household scale. Swap to count/limit queries if the
  # catalog ever grows large.
  defp load(socket) do
    movies = Catalog.list_watchlist()
    counts = Enum.frequencies_by(movies, & &1.status)
    recent = movies |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(8)

    assign(socket,
      pending: Requests.list_pending(),
      recent: recent,
      stats: %{
        movies_total: length(movies),
        movies_available: Map.get(counts, :available, 0),
        in_pipeline: Enum.sum(Enum.map(@pipeline, &Map.get(counts, &1, 0))),
        parked: Enum.sum(Enum.map(@parked, &Map.get(counts, &1, 0))),
        series_total: length(Catalog.list_series()),
        tv_wanted: length(Catalog.wanted_episodes()),
        downloading: length(Catalog.list_grabs_downloading())
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
    <div class="card bg-base-200 p-4">
      <div class="flex items-center gap-2 text-sm text-base-content/60">
        <.icon name={@icon} class="size-4" />{@label}
      </div>
      <div class="mt-1 text-2xl font-semibold tabular-nums">{@value}</div>
      <div :if={@suffix} class="text-xs text-base-content/50">{@suffix}</div>
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

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
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
            <.link navigate={~p"/requests"} class="link link-hover text-sm">
              {gettext("All requests →")}
            </.link>
          </div>
          <.empty_state
            :if={@pending == []}
            icon="hero-check-circle"
            title={gettext("Nothing to approve")}
            message={gettext("New requests appear here.")}
          />
          <ul :if={@pending != []} class="space-y-3">
            <li :for={r <- @pending} id={"pending-#{r.id}"} class="card bg-base-200 p-4">
              <div class="flex flex-row items-center gap-4">
                <img
                  :if={r.poster_path}
                  src={poster_url(r.poster_path, "w92")}
                  alt={r.title}
                  class="w-12 rounded"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-medium">
                    {if r.target_type == "season",
                      do:
                        gettext("%{title} — Season %{number}",
                          title: r.title,
                          number: r.season_number
                        ),
                      else: r.title}
                    <span :if={r.year} class="text-base-content/50">({r.year})</span>
                  </p>
                  <p class="truncate text-sm text-base-content/60">{r.user.email}</p>
                </div>
                <.status_badge kind={:request} status={r.status} />
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <button
                  class="btn btn-primary btn-sm"
                  phx-click="approve"
                  phx-value-id={r.id}
                  phx-disable-with={gettext("Approving…")}
                >
                  {gettext("Approve")}
                </button>
                <button
                  :if={@denying != to_string(r.id)}
                  class="btn btn-ghost btn-sm"
                  phx-click="start_deny"
                  phx-value-id={r.id}
                >
                  {gettext("Deny")}
                </button>
                <form
                  :if={@denying == to_string(r.id)}
                  phx-submit="deny"
                  class="flex flex-1 flex-wrap gap-2"
                >
                  <input type="hidden" name="_id" value={r.id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder={gettext("Reason (optional)")}
                    class="input input-sm input-bordered flex-1"
                  />
                  <button
                    type="submit"
                    class="btn btn-error btn-sm"
                    phx-disable-with={gettext("Denying…")}
                  >
                    {gettext("Confirm deny")}
                  </button>
                  <button type="button" class="btn btn-ghost btn-sm" phx-click="dismiss_deny">
                    {gettext("Cancel")}
                  </button>
                </form>
              </div>
            </li>
          </ul>
        </section>

        <div class="space-y-6">
          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{gettext("Service health")}</h2>
              <button
                class="btn btn-xs btn-ghost"
                phx-click="recheck_health"
                phx-disable-with={gettext("Checking…")}
                aria-label={gettext("Recheck service health")}
              >
                {gettext("Recheck")}
              </button>
            </div>
            <.spinner :if={@health == :loading} label={gettext("Checking services…")} />
            <ul
              :if={@health != :loading}
              id="dashboard-health"
              class="menu menu-sm w-full rounded-box bg-base-200"
            >
              <li :for={h <- @health}>
                <div class="flex items-center justify-between">
                  <span>{h.label}</span>
                  <.status_badge kind={:health} status={h.status} />
                </div>
              </li>
            </ul>
          </section>

          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{gettext("Recent activity")}</h2>
              <.link navigate={~p"/activity"} class="link link-hover text-sm">
                {gettext("View all →")}
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
                <span :if={m.year} class="text-sm text-base-content/50">({m.year})</span>
                <span class="ml-auto whitespace-nowrap text-xs text-base-content/40">
                  {Calendar.strftime(m.updated_at, "%b %-d")}
                </span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
