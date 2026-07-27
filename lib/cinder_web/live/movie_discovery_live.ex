defmodule CinderWeb.MovieDiscoveryLive do
  @moduledoc """
  Drill-in page for a TMDB movie, mounted at `/movie/tmdb/:tmdb_id`.

  The movie counterpart to `SeriesDiscoveryLive`'s season picker: a non-admin can open a title,
  read what it is, and request it from there. `/movies/:id` is the admin pipeline view of a movie
  Cinder already tracks; this is the catalog view of any TMDB movie, open to every signed-in user.

  Add flow, per-user badge state, and the defensive param parse + 404-vs-outage split are all
  shared with `EntityDiscoveryLive`.
  """
  use CinderWeb, :live_view

  import CinderWeb.DiscoverComponents
  import CinderWeb.IssueComponents, only: [report_form: 1, report_status: 1]
  import CinderWeb.LiveHelpers
  import CinderWeb.RequestHelpers

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Issues
  alias Cinder.Settings

  @picks Language.preferences()

  @impl true
  def mount(%{"tmdb_id" => raw}, _session, socket) do
    # The :tmdb_id param is client-controlled; a non-integer must not crash the page.
    with {tmdb_id, ""} <- Integer.parse(raw),
         {:ok, info} <- Catalog.get_movie(tmdb_id) do
      if connected?(socket) do
        # No series topic: this page renders one movie, and {:series_updated, _} fires once per
        # episode transition — a season-pack import would re-render every open movie page dozens
        # of times for nothing.
        Catalog.subscribe()
        Cinder.Requests.subscribe()
        Settings.subscribe()
        # An admin resolving this user's report re-offers the "Report an issue" action live.
        Issues.subscribe()
      end

      {:ok,
       socket
       |> assign(tmdb_id: tmdb_id, info: info, reporting: false)
       |> assign_media_server()
       |> assign_request_state()
       |> assign_report_state()}
    else
      # A TMDB outage is not "not found" — telling the user the movie doesn't exist sends them
      # away from a page that loads fine once TMDB is back.
      {:error, reason} when reason != {:tmdb_status, 404} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Couldn't reach TMDB. Please try again in a moment."))
         |> push_navigate(to: ~p"/")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Movie not found."))
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("add", %{"tmdb_id" => tmdb_id} = params, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only accept this page's id.
    preferred = normalize_language(params["preferred_language"])

    with {id, ""} <- Integer.parse(tmdb_id),
         true <- id == socket.assigns.tmdb_id,
         {:ok, profile} <- normalize_profile(params["proposed_media_profile"]) do
      {:noreply, add(socket, socket.assigns.info, preferred, profile)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_report", _params, socket),
    do: {:noreply, assign(socket, reporting: true)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: false)}

  # Report a problem with this (available) movie. The target is the page's own tmdb_id, never a
  # client value; only category + detail come from the form. Availability re-checked in the context.
  def handle_event("report_issue", params, socket) do
    user = socket.assigns.current_scope.user

    attrs = %{
      target_type: "movie",
      target_id: socket.assigns.tmdb_id,
      season_number: nil,
      category: params["category"],
      detail: params["detail"]
    }

    {:noreply,
     socket
     |> report_result(Issues.create_report(user, attrs))
     |> assign(reporting: false)}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp report_result(socket, {:ok, _report}),
    do:
      socket
      |> assign_report_state()
      |> put_flash(:info, gettext("Thanks! Your report was sent."))

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

  defp assign_report_state(socket) do
    user = socket.assigns.current_scope.user
    assign(socket, open_report?: Issues.open_report?(user, "movie", socket.assigns.tmdb_id))
  end

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

  def handle_info({event, _report}, socket)
      when event in [:issue_reported, :issue_resolved, :issue_dismissed] do
    {:noreply, assign_report_state(socket)}
  end

  def handle_info(:settings_updated, socket) do
    {:noreply, assign_media_server(socket)}
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

  # Re-read on every settings write rather than only at mount: an admin switching the
  # media-server type (or fixing a typo'd web URL) must not leave an already-open page linking
  # at the old server, which is the exact wrong-server case media_server_web_link/0 exists to
  # prevent. Two reads per page life (mount, plus each settings save) instead of one.
  defp assign_media_server(socket) do
    case Settings.media_server_web_link() do
      {server, url} -> assign(socket, media_server_url: url, media_server_name: name(server))
      nil -> assign(socket, media_server_url: nil, media_server_name: nil)
    end
  end

  # Product names, deliberately not gettext'd.
  defp name(:plex), do: "Plex"
  defp name(:jellyfin), do: "Jellyfin"

  # ponytail: only four valid values; default "original" on anything else (client-controlled).
  defp normalize_language(lang) when lang in @picks, do: lang
  defp normalize_language(_), do: "original"

  defp normalize_profile(nil), do: {:ok, nil}
  defp normalize_profile("auto"), do: {:ok, nil}
  defp normalize_profile("standard"), do: {:ok, :standard}
  defp normalize_profile("anime"), do: {:ok, :anime}
  defp normalize_profile(_), do: {:error, :invalid_media_profile}

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :state,
        title_state(assigns.tmdb_id, assigns.request_status, assigns.movie_status)
      )

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

      <div class="flex flex-col gap-6 sm:flex-row">
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
            <:actions>
              <.status_badge :if={@state != :none} kind={:request} status={@state} />
            </:actions>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@info.release_date} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@info.release_date)}
            </span>
            <span
              :if={is_integer(@info.runtime) and @info.runtime > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-clock" class="size-4" />{gettext("%{n} min", n: @info.runtime)}
            </span>
            <span
              :if={is_number(@info.vote_average) and @info.vote_average > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-star" class="size-4" />{rating(@info.vote_average)}
            </span>
          </div>

          <div :if={@info.genres not in [nil, []]} class="mt-3 flex flex-wrap gap-1">
            <span :for={g <- @info.genres} class="badge badge-outline badge-sm">{g}</span>
          </div>

          <p :if={media_overview(@info, @locale)} class="mt-4 max-w-prose text-sm leading-relaxed">
            {media_overview(@info, @locale)}
          </p>
          <p :if={is_nil(media_overview(@info, @locale))} class="mt-4 text-sm text-base-content/50">
            {gettext("No description available.")}
          </p>

          <.collection_link collection={@info[:collection]} />

          <%!-- Names the server and uses an external-link icon on purpose: this opens the media
                server's front door, NOT this title (Cinder stores no Plex ratingKey / Jellyfin
                Item Id), so a "Watch"-and-play-icon label would promise playback it can't
                deliver. Only shown once the file is actually in the library, and only when an
                operator has set a browser-reachable URL. --%>
          <.button
            :if={@state == :available and @media_server_url}
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

          <div :if={@state == :available} class="mt-4 flex flex-col gap-2">
            <.report_status :if={@open_report?} status={:open} />
            <.button
              :if={not @open_report? and not @reporting}
              id="report-issue"
              variant="ghost"
              size="sm"
              class="self-start"
              phx-click="start_report"
              aria-label={
                gettext("Report an issue with %{title}", title: media_title(@info, @locale))
              }
            >
              <.icon name="hero-flag" class="size-4" />{gettext("Report an issue")}
            </.button>
            <.report_form
              :if={@reporting}
              id="report-form"
              value={@tmdb_id}
              on_submit="report_issue"
              on_cancel="cancel_report"
              class="max-w-md"
            />
          </div>

          <form
            :if={@state in [:none, :denied]}
            id={"add-form-#{@tmdb_id}"}
            phx-submit="add"
            class="mt-4 flex max-w-xs flex-col gap-2"
          >
            <input type="hidden" name="tmdb_id" value={@tmdb_id} />
            <.language_select original_label={original_option_label(@info.original_language)} />
            <.media_profile_select />
            <.button
              type="submit"
              variant="primary"
              size="sm"
              aria-label={gettext("Add %{title}", title: media_title(@info, @locale))}
              phx-disable-with={gettext("Adding…")}
            >
              {gettext("Add")}
            </.button>
          </form>
        </div>
      </div>

      <.cast_strip cast={@info[:cast] || []} />
    </Layouts.app>
    """
  end
end
