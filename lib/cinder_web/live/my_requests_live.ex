defmodule CinderWeb.MyRequestsLive do
  @moduledoc """
  A requester's own requests, mounted at `/my-requests`. Shows each request's status
  (pending/approved/denied) and, once approved, the movie's live pipeline state
  (→ Available), plus a plain-English hint when a movie is parked or held on Anime
  preferences (read-only — retrying stays admin-only on `/activity`). A still-`:pending`
  request can be cancelled by its own requester. Live via the `"requests"` and `"movies"`
  PubSub topics.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers,
    only: [
      request_title: 2,
      movie_badge_status: 1,
      pipeline_hint: 1,
      anime_hold_reason: 1,
      find_by_id: 2
    ]

  alias Cinder.{Catalog, Requests}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      Catalog.subscribe()
      # Season availability derives from episode imports, which broadcast on "series".
      Catalog.subscribe_series()
    end

    {:ok, socket |> assign(confirming: nil) |> load()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("ask_cancel", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: id)}

  def handle_event("dismiss_cancel", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("cancel_request", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    socket =
      case find_by_id(socket.assigns.requests, id) do
        nil ->
          socket

        request ->
          case Requests.cancel_own_request(request, user) do
            {:ok, _} -> socket |> load() |> put_flash(:info, gettext("Request cancelled."))
            {:error, _} -> put_flash(socket, :error, gettext("Couldn't cancel that request."))
          end
      end

    {:noreply, assign(socket, confirming: nil)}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      requests: Requests.list_for_user(user),
      movies_by_tmdb: Map.new(Catalog.list_movies(), &{&1.tmdb_id, &1}),
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
        <li :for={r <- @requests} id={"request-#{r.id}"} class="rounded-box bg-base-200/50 p-4">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <% movie = @movies_by_tmdb[r.target_id] %>
            <% movie_row? = r.target_type == "movie" and not is_nil(movie) %>
            <span class="min-w-0 break-words font-semibold">
              {request_title(r, @locale)}
            </span>
            <span :if={r.year} class="text-base-content/70">({r.year})</span>
            <.status_badge kind={:request} status={effective_status(r, @available_seasons)} />
            <.status_badge
              :if={movie_row?}
              kind={:movie}
              status={movie_badge_status(movie)}
              progress={movie.download_progress}
              speed={movie.download_speed}
              eta={movie.download_eta}
            />
            <.button
              :if={r.status == :pending and @confirming != to_string(r.id)}
              id={"cancel-request-#{r.id}"}
              variant="ghost"
              size="sm"
              class="ml-auto text-error"
              phx-click="ask_cancel"
              phx-value-id={r.id}
            >
              {gettext("Cancel request")}
            </.button>
          </div>
          <p
            :if={effective_status(r, @available_seasons) == :denied and r.denial_reason}
            class="mt-1 flex items-start gap-1.5 text-sm text-error"
          >
            <.icon name="hero-x-circle" class="mt-0.5 size-4 shrink-0" />
            <span class="min-w-0 break-words"><span class="font-medium">{gettext("Reason:")}</span> {r.denial_reason}</span>
          </p>
          <p
            :if={movie_row? and movie_badge_status(movie) == :anime_hold}
            id={"request-#{r.id}-hold-reason"}
            class="mt-1 text-sm text-base-content/70"
          >
            {anime_hold_reason(movie.anime_hold_reason)}
          </p>
          <p
            :if={movie_row? and movie_badge_status(movie) != :anime_hold and pipeline_hint(movie)}
            id={"request-#{r.id}-hint"}
            class="mt-1 text-sm text-base-content/70"
          >
            {pipeline_hint(movie)}
          </p>
          <.confirm_action
            :if={@confirming == to_string(r.id)}
            id={"confirm-cancel-request-#{r.id}"}
            on_confirm="cancel_request"
            on_cancel="dismiss_cancel"
            value={r.id}
            confirm_label={gettext("Cancel request")}
            variant="warning"
            class="mt-2"
          >
            <:caveat>
              {gettext("Cancel this request? You can request it again later.")}
            </:caveat>
          </.confirm_action>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
