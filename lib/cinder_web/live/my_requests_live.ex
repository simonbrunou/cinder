defmodule CinderWeb.MyRequestsLive do
  @moduledoc """
  A requester's own requests, mounted at `/my-requests`. Shows each request's status
  (pending/approved/denied) and, once approved, the movie's live pipeline state
  (→ Available). Live via the `"requests"` and `"movies"` PubSub topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [request_title: 1]

  alias Cinder.{Catalog, Requests}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      Catalog.subscribe()
      # Season availability derives from episode imports, which broadcast on "series".
      Catalog.subscribe_series()
    end

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  # The view renders no interactive elements, but event payloads are client-controlled —
  # ignore a forged frame rather than crash the LiveView (house rule).
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      requests: Requests.list_for_user(user),
      movie_status: Catalog.movie_status_map(),
      available_seasons: Catalog.available_season_keys()
    )
  end

  # Availability outranks a stale season request status (mirrors the movie title_state
  # precedence): a fully imported season must not keep reading "Denied" — one badge,
  # not contradictory stacked ones, and no stale denial-reason line.
  defp effective_status(%{target_type: "season", target_id: t, season_number: n} = r, available) do
    if MapSet.member?(available, {t, n}), do: :available, else: r.status
  end

  defp effective_status(r, _available), do: r.status

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("My requests")}
        <:subtitle>{gettext("Track what you've asked for.")}</:subtitle>
      </.header>

      <.empty_state
        :if={@requests == []}
        icon="hero-bookmark"
        title={gettext("No requests yet")}
        message={gettext("Search the catalog to request a title.")}
      />

      <ul id="my-requests" class="space-y-3">
        <li :for={r <- @requests} class="rounded-box bg-base-200/50 p-4">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <span class="min-w-0 break-words font-semibold">
              {request_title(r)}
            </span>
            <span :if={r.year} class="text-base-content/70">({r.year})</span>
            <.status_badge kind={:request} status={effective_status(r, @available_seasons)} />
            <.status_badge
              :if={r.target_type == "movie" and @movie_status[r.target_id]}
              kind={:movie}
              status={@movie_status[r.target_id]}
            />
          </div>
          <p
            :if={effective_status(r, @available_seasons) == :denied and r.denial_reason}
            class="mt-1 flex items-start gap-1.5 text-sm text-error"
          >
            <.icon name="hero-x-circle" class="mt-0.5 size-4 shrink-0" />
            <span class="min-w-0 break-words"><span class="font-medium">{gettext("Reason:")}</span> {r.denial_reason}</span>
          </p>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
