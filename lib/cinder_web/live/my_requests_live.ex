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
      relative_time: 1,
      find_by_id: 2
    ]

  import CinderWeb.IssueComponents, only: [report_form: 1, report_status: 1]

  alias Cinder.{Catalog, Issues, Requests, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      Catalog.subscribe()
      # Season availability derives from episode imports, which broadcast on "series".
      Catalog.subscribe_series()
      # An admin resolving/dismissing a report updates its status here live.
      Issues.subscribe()
    end

    {:ok, socket |> assign(confirming: nil, reporting: nil) |> load()}
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

  # Re-submit a denied request through the normal gate (quota + approval intact). The TMDB
  # lookup inside create_request runs off-process so a slow provider can't freeze the page.
  def handle_event("request_again", %{"id" => id}, socket) do
    socket =
      case find_by_id(socket.assigns.requests, id) do
        %{status: :denied} = request -> start_request_again(socket, request)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("start_report", %{"id" => id}, socket),
    do: {:noreply, assign(socket, reporting: id)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: nil)}

  # File a problem report against one of the caller's own available titles. The target is taken
  # from the server-side request row (never a client-supplied target); only the category + detail
  # come from the form. Availability is re-checked in Issues.create_report/2.
  def handle_event("report_issue", %{"_id" => id} = params, socket) do
    user = socket.assigns.current_scope.user

    socket =
      case find_by_id(socket.assigns.requests, id) do
        nil ->
          socket

        request ->
          report_result(socket, Issues.create_report(user, report_attrs(request, params)))
      end

    {:noreply, assign(socket, reporting: nil)}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp report_attrs(request, params) do
    %{
      target_type: request.target_type,
      target_id: request.target_id,
      season_number: request.season_number,
      category: params["category"],
      detail: params["detail"]
    }
  end

  defp report_result(socket, {:ok, _report}),
    do: socket |> load() |> put_flash(:info, gettext("Thanks! Your report was sent."))

  defp report_result(socket, {:error, :too_many_open}),
    do:
      put_flash(
        socket,
        :error,
        gettext("You have too many open reports. Please wait for an admin to review them.")
      )

  defp report_result(socket, {:error, :not_available}),
    do: put_flash(socket, :error, gettext("You can only report an issue on an available title."))

  defp report_result(socket, {:error, _reason}),
    do: put_flash(socket, :error, gettext("Couldn't send that report. Please try again."))

  @impl true
  def handle_async({:request_again, title}, {:ok, result}, socket),
    do: {:noreply, request_again_result(socket, title, result)}

  def handle_async({:request_again, title}, {:exit, _reason}, socket),
    do:
      {:noreply,
       put_flash(socket, :error, gettext("Couldn't request %{title}. Try again.", title: title))}

  defp start_request_again(socket, request) do
    user = socket.assigns.current_scope.user
    attrs = request_again_attrs(request)
    title = request_title(request, socket.assigns.locale)

    start_async(socket, {:request_again, title}, fn ->
      Requests.create_request(user, attrs)
    end)
  end

  defp request_again_attrs(r) do
    %{
      target_type: r.target_type,
      target_id: r.target_id,
      season_number: r.season_number,
      title: r.title,
      year: r.year,
      poster_path: r.poster_path,
      original_language: r.original_language,
      preferred_language: r.preferred_language,
      proposed_media_profile: r.proposed_media_profile
    }
  end

  defp request_again_result(socket, title, {:ok, %{status: :approved}}),
    do: socket |> load() |> put_flash(:info, gettext("%{title} added.", title: title))

  defp request_again_result(socket, title, {:ok, %{status: :pending}}),
    do:
      socket
      |> load()
      |> put_flash(:info, gettext("%{title} requested. Awaiting approval.", title: title))

  defp request_again_result(socket, _title, {:error, :quota_exceeded}),
    do:
      put_flash(
        socket,
        :error,
        gettext("You've reached your request limit. Wait for approvals to clear.")
      )

  defp request_again_result(socket, title, {:error, _reason}),
    do: put_flash(socket, :error, gettext("Couldn't request %{title}. Try again.", title: title))

  defp load(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(
      requests: Requests.list_for_user(user),
      movies_by_tmdb: Map.new(Catalog.list_movies(), &{&1.tmdb_id, &1}),
      available_seasons: Catalog.available_season_keys(),
      season_progress: Catalog.season_progress_keys(),
      latest_report_by_target: latest_reports(user)
    )
    |> assign_media_server()
  end

  # The caller's newest report per target (`list_for_user` is desc by id, so the first seen per
  # key is the latest) — drives the per-row "Reported/Resolved/Dismissed" pill and whether the
  # "Report an issue" affordance is still offered.
  defp latest_reports(user) do
    user
    |> Issues.list_for_user()
    |> Enum.reduce(%{}, fn report, acc -> Map.put_new(acc, report_key(report), report) end)
  end

  defp report_key(%{target_type: type, target_id: id, season_number: n}), do: {type, id, n}

  # Re-read the media-server front door on every reload (mount + each broadcast), not just at
  # mount, so an admin switching the server type or fixing a typo'd web URL can't leave an open
  # page linking at the old server — the wrong-server case `media_server_web_link/0` guards.
  defp assign_media_server(socket) do
    case Settings.media_server_web_link() do
      {server, url} ->
        assign(socket, media_server_url: url, media_server_name: server_name(server))

      nil ->
        assign(socket, media_server_url: nil, media_server_name: nil)
    end
  end

  # Product names, deliberately not gettext'd.
  defp server_name(:plex), do: "Plex"
  defp server_name(:jellyfin), do: "Jellyfin"

  defp season_row?(%{target_type: "season"}), do: true
  defp season_row?(_), do: false

  # Progress for a season request row, keyed by `{series tmdb_id, season_number}`; nil for a
  # movie row or a season with no episodes yet (still pending an admin's approval).
  defp season_progress(%{target_type: "season", target_id: t, season_number: n}, progress),
    do: Map.get(progress, {t, n})

  defp season_progress(_r, _progress), do: nil

  # Whether the whole row's content has landed — a fully-available season, or an available movie.
  defp row_available?(%{target_type: "season"} = r, _movie, available_seasons),
    do: effective_status(r, available_seasons) == :available

  defp row_available?(_r, movie, _available_seasons),
    do: not is_nil(movie) and movie_badge_status(movie) == :available

  defp season_downloading?(%{downloading: true}), do: true
  defp season_downloading?(_), do: false

  defp season_incomplete?(%{total: total, available: available})
       when total > 0 and available < total,
       do: true

  defp season_incomplete?(_), do: false

  defp season_progress_hint(%{total: total, available: available}) do
    ngettext(
      "%{available} of %{count} episode available",
      "%{available} of %{count} episodes available",
      total,
      available: available
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
    >
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
            <% season_progress = season_progress(r, @season_progress) %>
            <% available? = row_available?(r, movie, @available_seasons) %>
            <% report = @latest_report_by_target[report_key(r)] %>
            <% open_report? = match?(%{status: :open}, report) %>
            <span class="min-w-0 break-words font-semibold">
              {request_title(r, @locale)}
            </span>
            <span :if={r.year} class="text-base-content/70">({r.year})</span>
            <.status_badge kind={:request} status={effective_status(r, @available_seasons)} />
            <.report_status :if={report} status={report.status} />
            <.status_badge
              :if={movie_row?}
              kind={:movie}
              status={movie_badge_status(movie)}
              progress={movie.download_progress}
              speed={movie.download_speed}
              eta={movie.download_eta}
            />
            <.status_badge
              :if={season_row?(r) and not available? and season_downloading?(season_progress)}
              kind={:episode}
              status={:downloading}
            />
            <.button
              :if={available? and @media_server_url}
              href={@media_server_url}
              target="_blank"
              rel="noopener"
              variant="primary"
              size="sm"
              class="ml-auto"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />{gettext(
                "Open in %{server}",
                server: @media_server_name
              )}
              <span class="sr-only">{gettext("(opens in a new tab)")}</span>
            </.button>
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
            <.button
              :if={effective_status(r, @available_seasons) == :denied}
              id={"request-again-#{r.id}"}
              variant="ghost"
              size="sm"
              class="ml-auto"
              phx-click="request_again"
              phx-value-id={r.id}
              aria-label={gettext("Request %{title} again", title: request_title(r, @locale))}
            >
              {gettext("Request again")}
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
          <p
            :if={season_incomplete?(season_progress)}
            id={"request-#{r.id}-season-progress"}
            class="mt-1 text-sm text-base-content/70"
          >
            {season_progress_hint(season_progress)}
          </p>
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Requested %{time_ago}", time_ago: relative_time(r.inserted_at))}
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

          <.button
            :if={available? and not open_report? and @reporting != to_string(r.id)}
            id={"report-issue-#{r.id}"}
            variant="ghost"
            size="sm"
            class="mt-2"
            phx-click="start_report"
            phx-value-id={r.id}
            aria-label={gettext("Report an issue with %{title}", title: request_title(r, @locale))}
          >
            <.icon name="hero-flag" class="size-4" />{gettext("Report an issue")}
          </.button>

          <.report_form
            :if={@reporting == to_string(r.id)}
            id={"report-form-#{r.id}"}
            value={r.id}
            on_submit="report_issue"
            on_cancel="cancel_report"
            class="mt-2 max-w-md"
          />
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
