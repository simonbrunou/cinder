defmodule CinderWeb.SeriesDetailLive do
  @moduledoc """
  Admin-only series detail at `/series/:id`: the season/episode tree with per-episode
  monitor toggles and a per-season bulk control. Writes go straight through
  `Catalog.set_episode_monitored/2` / `set_season_monitored/2` (monitor flags aren't
  pipeline state, so no `Catalog.transition`). Subscribes to the `"series"` topic so a
  second open tab reflects a toggle.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [format_date_year: 1, humanize_bytes: 1, rating: 1]

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # The :id param is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %{} = series <- Catalog.get_series_with_tree(id) do
      if connected?(socket), do: Catalog.subscribe_series()

      socket =
        assign(socket,
          series: series,
          editing?: false,
          confirming: nil,
          form: nil,
          confirm_opt: false,
          searching_season: nil
        )

      {:ok, maybe_enrich(socket, series)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Series not found."))
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def handle_event("toggle_episode", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id) do
      case Catalog.set_episode_monitored(ep, !ep.monitored) do
        {:ok, _} ->
          {:noreply, reload(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't update the episode."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_season", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      # Bulk action: if every episode is already monitored, turn the season off; else on.
      case Catalog.set_season_monitored(season, not all_monitored?(season)) do
        {:ok, _} ->
          {:noreply, reload(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't update the season."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("edit_series", _params, socket) do
    form = to_form(Series.admin_changeset(socket.assigns.series, %{}))
    {:noreply, assign(socket, editing?: true, confirming: nil, form: form)}
  end

  def handle_event("cancel_edit_series", _params, socket) do
    {:noreply, assign(socket, editing?: false, form: nil)}
  end

  def handle_event("save_series", %{"series" => attrs}, socket) do
    case Catalog.update_series(socket.assigns.series, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing?: false, form: nil)
         |> put_flash(:info, gettext("Series updated."))
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("ask_cancel_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :cancel, editing?: false, confirm_opt: false)}

  def handle_event("ask_delete_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :delete, editing?: false, confirm_opt: false)}

  def handle_event("ask_delete_episode_file", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:episode_file, id}, confirm_opt: false)}

  def handle_event("ask_delete_season_files", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:season_files, id}, confirm_opt: false)}

  def handle_event("toggle_confirm_opt", _params, socket),
    do: {:noreply, assign(socket, confirm_opt: !socket.assigns.confirm_opt)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, confirm_opt: false)}

  def handle_event("confirm_cancel_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.cancel_series(socket.assigns.series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:info, gettext("Series cancelled."))
         |> reload()}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't cancel the series."))}
    end
  end

  def handle_event("confirm_delete_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_series(socket.assigns.series, actor,
           delete_files: socket.assigns.confirm_opt
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Series deleted.")) |> push_navigate(to: ~p"/library")}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the series."))}
    end
  end

  def handle_event("confirm_delete_episode_file", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id),
         {:ok, _} <- Catalog.delete_episode_file(ep, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply,
       socket
       |> assign(confirming: nil)
       |> put_flash(:info, gettext("Episode file deleted."))
       |> reload()}
    else
      {:error, :no_file} ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("That episode has no file."))}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the episode file."))}
    end
  end

  def handle_event("confirm_delete_season_files", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      result = Catalog.delete_season_files(season, actor, unmonitor: socket.assigns.confirm_opt)
      socket = assign(socket, confirming: nil)

      socket =
        case result do
          {:ok, cleared, 0} ->
            put_flash(socket, :info, gettext("Deleted %{count} file(s).", count: cleared))

          {:ok, cleared, failed} when cleared > 0 ->
            put_flash(
              socket,
              :warning,
              gettext(
                "Deleted %{cleared} file(s); %{failed} could not be deleted (see server logs).",
                cleared: cleared,
                failed: failed
              )
            )

          {:ok, _cleared, _failed} ->
            put_flash(
              socket,
              :error,
              gettext("Couldn't delete the season's files (see server logs).")
            )

          _ ->
            put_flash(socket, :error, gettext("Couldn't delete the season files."))
        end

      {:noreply, reload(socket)}
    else
      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, gettext("Couldn't delete the season files."))}
    end
  end

  def handle_event("set_series_language", %{"preferred_language" => lang}, socket)
      when lang in ["original", "french", "any"] do
    case Catalog.set_series_language(socket.assigns.series, lang) do
      {:ok, series} -> {:noreply, assign(socket, :series, series)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("search_episode", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id) do
      Catalog.search_episode_now(ep)
      {:noreply, put_flash(socket, :info, gettext("Searching for this episode…"))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("search_season", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id) do
      Catalog.search_season_now(season)
      {:noreply, put_flash(socket, :info, gettext("Searching for missing episodes…"))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Toggle the manual-search panel for a season (re-clicking the open season closes it).
  def handle_event("tv_manual_search", %{"season" => n}, socket) do
    case Integer.parse(n) do
      {season, ""} ->
        open = if socket.assigns.searching_season == season, do: nil, else: season
        {:noreply, assign(socket, searching_season: open)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Backfill descriptive metadata once, off the render path (vote_average-nil sentinel).
  defp maybe_enrich(socket, %Series{vote_average: nil} = series) do
    if connected?(socket),
      do: start_async(socket, :enrich, fn -> Catalog.enrich_series(series) end),
      else: socket
  end

  defp maybe_enrich(socket, %Series{}), do: socket

  # Metadata backfill landed — reload so the tree + the newly-written descriptive fields render.
  @impl true
  def handle_async(:enrich, {:ok, %Series{}}, socket), do: {:noreply, reload(socket)}
  def handle_async(:enrich, {:exit, _reason}, socket), do: {:noreply, socket}

  # The manual-search panel forwards a chosen release back here (it owns no Catalog writes). The
  # open panel's season is tracked in :searching_season; the grab covers that season's wanted set.
  @impl true
  def handle_info({:manual_grab, :tv, series, release}, socket) do
    {level, msg} =
      case Catalog.manual_grab_tv(series, socket.assigns.searching_season, release) do
        {:ok, _grab} -> {:info, gettext("Grabbing the selected release…")}
        {:error, :nothing_wanted} -> {:error, gettext("Nothing left to grab this season.")}
        {:error, _} -> {:error, gettext("Couldn't grab that release.")}
      end

    {:noreply, socket |> assign(searching_season: nil) |> put_flash(level, msg) |> reload()}
  end

  def handle_info({:series_updated, id}, socket) do
    if id == socket.assigns.series.id, do: {:noreply, reload(socket)}, else: {:noreply, socket}
  end

  def handle_info({:series_deleted, id}, socket) do
    if socket.assigns.series.id == id do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Series deleted."))
       |> push_navigate(to: ~p"/library")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Guard the series vanishing out from under an open page (no delete path today, but a
  # reload that assigned nil would nil-deref the next render): bounce back to the list.
  defp reload(socket) do
    case Catalog.get_series_with_tree(socket.assigns.series.id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Series not found."))
        |> push_navigate(to: ~p"/library")

      series ->
        assign(socket, series: series)
    end
  end

  defp find_episode(series, id) do
    series.seasons |> Enum.flat_map(& &1.episodes) |> Enum.find(&(&1.id == id))
  end

  defp find_season(series, id), do: Enum.find(series.seasons, &(&1.id == id))

  defp all_monitored?(%{episodes: []}), do: false
  defp all_monitored?(%{episodes: eps}), do: Enum.all?(eps, & &1.monitored)

  # A season has something the search sweep would actually pick up. Gates the per-season
  # "Search all missing" and "Find a better match" controls; mirrors the per-episode "Search"
  # button.
  defp season_wanted?(%{episodes: eps, season_number: n}),
    do: Enum.any?(eps, &episode_searchable?(&1, n))

  # Mirrors Catalog.wanted_episodes_query/0 exactly: an episode the TV sweep would grab. A
  # monitored, file-less, grab-less episode is NOT enough — it must also be in a real season
  # (> 0, no specials), a real episode (> 0), and already aired (dated, air_date <= today).
  # Keeping this in lock-step with the query avoids a "Search…" affordance that never grabs.
  defp episode_searchable?(ep, season_number) do
    is_nil(ep.file_path) and is_nil(ep.grab_id) and ep.monitored and season_number > 0 and
      ep.episode_number > 0 and not is_nil(ep.air_date) and
      Date.compare(ep.air_date, Date.utc_today()) != :gt
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/library"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Library")}
      </.link>

      <div class="mb-4 flex flex-wrap items-center gap-2">
        <.button type="button" variant="neutral" size="sm" phx-click="edit_series">
          {gettext("Edit")}
        </.button>
        <.button type="button" variant="warning" size="sm" phx-click="ask_cancel_series">
          {gettext("Cancel series")}
        </.button>
        <.button type="button" variant="danger" size="sm" phx-click="ask_delete_series">
          {gettext("Delete series")}
        </.button>
      </div>

      <.form
        :if={@editing?}
        for={@form}
        id="series-form"
        phx-submit="save_series"
        class="mb-6 flex flex-wrap items-end gap-2"
      >
        <.input field={@form[:title]} type="text" label={gettext("Title")} />
        <.input field={@form[:year]} type="number" label={gettext("Year")} />
        <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
          {gettext("Save")}
        </.button>
        <.button variant="ghost" size="sm" type="button" phx-click="cancel_edit_series">
          {gettext("Cancel")}
        </.button>
      </.form>

      <.confirm_action
        :if={@confirming == :cancel}
        id="confirm-cancel-series"
        on_confirm="confirm_cancel_series"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Cancel series")}
        variant="warning"
      >
        <:caveat>
          {gettext("Cancel this series? Removes its downloads and unmonitors everything.")}
        </:caveat>
      </.confirm_action>

      <.confirm_action
        :if={@confirming == :delete}
        id="confirm-delete-series"
        class="mb-6"
        on_confirm="confirm_delete_series"
        on_cancel="dismiss_confirm"
        confirm_label={gettext("Delete")}
        checkbox_event="toggle_confirm_opt"
        checkbox_checked={@confirm_opt}
        checkbox_label={gettext("Also delete files from disk")}
      >
        <:caveat>{gettext("Delete this series and its seasons/episodes?")}</:caveat>
      </.confirm_action>

      <div class="mb-8 flex gap-4">
        <img
          :if={@series.poster_path}
          src={poster_url(@series.poster_path)}
          alt={@series.title}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-24 rounded object-cover"
        />
        <div class="min-w-0 flex-1">
          <.header>
            {@series.title}
            <span :if={@series.year} class="font-normal text-base-content/70">({@series.year})</span>
            <:actions>
              <.status_badge kind={:monitored} status={@series.monitored} />
            </:actions>
          </.header>

          <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/70">
            <span :if={@series.first_air_date} class="inline-flex items-center gap-1">
              <.icon name="hero-calendar" class="size-4" />{format_date_year(@series.first_air_date)}
            </span>
            <span
              :if={is_number(@series.vote_average) and @series.vote_average > 0}
              class="inline-flex items-center gap-1"
            >
              <.icon name="hero-star" class="size-4" />{rating(@series.vote_average)}
            </span>
          </div>

          <div :if={@series.genres not in [nil, []]} class="mt-2 flex flex-wrap gap-1">
            <span :for={g <- @series.genres} class="badge badge-outline badge-sm">{g}</span>
          </div>

          <p :if={@series.overview} class="mt-3 max-w-prose text-sm leading-relaxed">
            {@series.overview}
          </p>
        </div>
      </div>

      <form id="series-detail-language-form" phx-change="set_series_language" class="mb-4 max-w-xs">
        <.language_select value={@series.preferred_language} />
      </form>

      <.empty_state
        :if={@series.seasons == []}
        icon="hero-tv"
        title={gettext("No seasons found")}
        message={gettext("TMDB returned no season data for this series.")}
      />

      <section :for={season <- @series.seasons} class="mb-6">
        <div class="mb-2 flex flex-wrap items-center justify-between gap-2 border-b border-base-300 pb-2">
          <h2 class="text-lg font-semibold">
            {season_label(season.season_number)}
            <span class="ml-2 text-sm font-normal text-base-content/70">
              {gettext("%{n}/%{m} monitored",
                n: monitored_count(season),
                m: length(season.episodes)
              )}
            </span>
          </h2>
          <div class="flex flex-wrap items-center gap-2">
            <.button
              :if={season.episodes != []}
              type="button"
              phx-click="toggle_season"
              phx-value-id={season.id}
              variant="neutral"
              size="sm"
              aria-label={
                if all_monitored?(season),
                  do:
                    gettext("Unmonitor all episodes in %{season}",
                      season: season_label(season.season_number)
                    ),
                  else:
                    gettext("Monitor all episodes in %{season}",
                      season: season_label(season.season_number)
                    )
              }
            >
              {if all_monitored?(season), do: gettext("Unmonitor all"), else: gettext("Monitor all")}
            </.button>
            <.button
              :if={Enum.any?(season.episodes, & &1.file_path)}
              type="button"
              variant="danger"
              size="sm"
              phx-click="ask_delete_season_files"
              phx-value-id={season.id}
              aria-label={
                gettext("Delete all files in %{season}", season: season_label(season.season_number))
              }
            >
              {gettext("Delete files")}
            </.button>
            <.button
              :if={season_wanted?(season)}
              type="button"
              variant="neutral"
              size="sm"
              phx-click="search_season"
              phx-value-id={season.id}
              aria-label={
                gettext("Search all missing episodes in %{season}",
                  season: season_label(season.season_number)
                )
              }
            >
              {gettext("Search all missing")}
            </.button>
            <.button
              :if={season_wanted?(season)}
              type="button"
              variant="ghost"
              size="sm"
              phx-click="tv_manual_search"
              phx-value-season={season.season_number}
            >
              {gettext("Find a better match")}
            </.button>
          </div>
        </div>

        <.live_component
          :if={@searching_season == season.season_number}
          module={CinderWeb.ManualSearchComponent}
          id={"ms-season-#{season.id}"}
          mode={:tv}
          target={@series}
          season_number={season.season_number}
        />

        <.confirm_action
          :if={@confirming == {:season_files, to_string(season.id)}}
          id={"confirm-delete-season-files-#{season.id}"}
          class="mb-2"
          on_confirm="confirm_delete_season_files"
          on_cancel="dismiss_confirm"
          value={season.id}
          confirm_label={gettext("Delete files")}
          checkbox_event="toggle_confirm_opt"
          checkbox_checked={@confirm_opt}
          checkbox_label={gettext("Also stop monitoring these episodes")}
        >
          <:caveat>
            {gettext(
              "Delete every downloaded file in %{season}? Monitored episodes will be re-downloaded next sweep unless you also stop monitoring.",
              season: season_label(season.season_number)
            )}
          </:caveat>
        </.confirm_action>

        <p :if={season.episodes == []} class="text-sm text-base-content/70">
          {gettext("No episodes yet.")}
        </p>
        <ul class="divide-y divide-base-200">
          <li :for={ep <- season.episodes} class="flex flex-col gap-2 py-2">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
              <div class="flex min-w-0 items-center gap-3 sm:flex-1">
                <input
                  type="checkbox"
                  class="toggle shrink-0"
                  checked={ep.monitored}
                  phx-click="toggle_episode"
                  phx-value-id={ep.id}
                  aria-label={
                    gettext("Monitor %{season} episode %{number}",
                      season: season_label(season.season_number),
                      number: ep.episode_number
                    )
                  }
                />
                <span class="w-8 shrink-0 text-sm tabular-nums text-base-content/70">{ep.episode_number}</span>
                <span class="min-w-0 flex-1 break-words text-sm">{ep.title}</span>
                <span
                  :if={
                    ep.file_path &&
                      (ep.imported_audio_languages || []) ++
                        (ep.imported_embedded_subtitles || []) ++
                        (ep.imported_sidecar_subtitles || []) != []
                  }
                  class="ml-2 inline-flex flex-wrap gap-1 align-middle"
                >
                  <span
                    :for={l <- ep.imported_audio_languages}
                    class="badge badge-ghost badge-xs"
                    aria-label={gettext("audio %{lang}", lang: l)}
                  >{l}</span>
                  <span
                    :for={
                      l <-
                        (ep.imported_embedded_subtitles || []) ++
                          (ep.imported_sidecar_subtitles || [])
                    }
                    class="badge badge-outline badge-xs"
                    aria-label={gettext("subtitle %{lang}", lang: l)}
                  >{l}</span>
                </span>
              </div>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 pl-11 sm:pl-0">
                <time
                  :if={ep.air_date}
                  datetime={Date.to_iso8601(ep.air_date)}
                  class="text-xs text-base-content/70"
                >
                  {format_date_year(ep.air_date)}
                </time>
                <span
                  :if={ep.file_path && episode_file_info(ep) != ""}
                  class="text-xs text-base-content/60"
                >
                  {episode_file_info(ep)}
                </span>
                <.button
                  :if={ep.file_path}
                  type="button"
                  variant="danger"
                  size="sm"
                  phx-click="ask_delete_episode_file"
                  phx-value-id={ep.id}
                  aria-label={
                    gettext("Delete file for %{season} episode %{number}",
                      season: season_label(season.season_number),
                      number: ep.episode_number
                    )
                  }
                >
                  {gettext("Delete file")}
                </.button>
                <.button
                  :if={episode_searchable?(ep, season.season_number)}
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="search_episode"
                  phx-value-id={ep.id}
                  aria-label={gettext("Search for episode %{number}", number: ep.episode_number)}
                >
                  {gettext("Search")}
                </.button>
              </div>
            </div>
            <.confirm_action
              :if={@confirming == {:episode_file, to_string(ep.id)}}
              id={"confirm-delete-episode-file-#{ep.id}"}
              on_confirm="confirm_delete_episode_file"
              on_cancel="dismiss_confirm"
              value={ep.id}
              confirm_label={gettext("Delete file")}
              checkbox_event="toggle_confirm_opt"
              checkbox_checked={@confirm_opt}
              checkbox_label={gettext("Also stop monitoring this episode")}
            >
              <:caveat>
                {gettext(
                  "Delete the downloaded file for this episode? If it stays monitored it will be downloaded again. Stop monitoring it to keep it gone."
                )}
              </:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp monitored_count(season), do: Enum.count(season.episodes, & &1.monitored)

  # "1080p · 2.1 GB" for a downloaded episode — drops whichever piece TMDB/import didn't capture.
  defp episode_file_info(ep) do
    [ep.imported_resolution, humanize_bytes(ep.imported_size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
