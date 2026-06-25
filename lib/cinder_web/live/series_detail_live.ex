defmodule CinderWeb.SeriesDetailLive do
  @moduledoc """
  Admin-only series detail at `/series/:id`: the season/episode tree with per-episode
  monitor toggles and a per-season bulk control. Writes go straight through
  `Catalog.set_episode_monitored/2` / `set_season_monitored/2` (monitor flags aren't
  pipeline state, so no `Catalog.transition`). Subscribes to the `"series"` topic so a
  second open tab reflects a toggle.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # The :id param is client-controlled; a non-integer must not reach Repo.get (CastError).
    with {id, ""} <- Integer.parse(id),
         %{} = series <- Catalog.get_series_with_tree(id) do
      if connected?(socket), do: Catalog.subscribe_series()

      {:ok,
       assign(socket,
         series: series,
         editing?: false,
         confirming: nil,
         form: nil,
         confirm_opt: false
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Series not found.")
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def handle_event("toggle_episode", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id) do
      case Catalog.set_episode_monitored(ep, !ep.monitored) do
        {:ok, _} -> {:noreply, reload(socket)}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't update the episode.")}
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
        {:ok, _} -> {:noreply, reload(socket)}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't update the season.")}
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
         |> put_flash(:info, "Series updated.")
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
         socket |> assign(confirming: nil) |> put_flash(:info, "Series cancelled.") |> reload()}

      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't cancel the series.")}
    end
  end

  def handle_event("confirm_delete_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_series(socket.assigns.series, actor,
           delete_files: socket.assigns.confirm_opt
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Series deleted.") |> push_navigate(to: ~p"/library")}

      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the series.")}
    end
  end

  def handle_event("confirm_delete_episode_file", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id),
         {:ok, _} <- Catalog.delete_episode_file(ep, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply,
       socket |> assign(confirming: nil) |> put_flash(:info, "Episode file deleted.") |> reload()}
    else
      {:error, :no_file} ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "That episode has no file.")}

      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, "Couldn't delete the episode file.")}
    end
  end

  def handle_event("confirm_delete_season_files", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id),
         {:ok, n} <-
           Catalog.delete_season_files(season, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply,
       socket |> assign(confirming: nil) |> put_flash(:info, "Deleted #{n} file(s).") |> reload()}
    else
      _ ->
        {:noreply,
         socket
         |> assign(confirming: nil)
         |> put_flash(:error, "Couldn't delete the season files.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:series_updated, id}, socket) do
    if id == socket.assigns.series.id, do: {:noreply, reload(socket)}, else: {:noreply, socket}
  end

  def handle_info({:series_deleted, id}, socket) do
    if socket.assigns.series.id == id do
      {:noreply,
       socket
       |> put_flash(:info, "Series deleted.")
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
      nil -> socket |> put_flash(:error, "Series not found.") |> push_navigate(to: ~p"/library")
      series -> assign(socket, series: series)
    end
  end

  defp find_episode(series, id) do
    series.seasons |> Enum.flat_map(& &1.episodes) |> Enum.find(&(&1.id == id))
  end

  defp find_season(series, id), do: Enum.find(series.seasons, &(&1.id == id))

  defp all_monitored?(%{episodes: []}), do: false
  defp all_monitored?(%{episodes: eps}), do: Enum.all?(eps, & &1.monitored)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :poster_base, @poster_base)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.link navigate={~p"/library"} class="link mb-6 inline-block">← Library</.link>

      <div class="mb-4 flex flex-wrap items-center gap-2">
        <button type="button" class="btn btn-sm" phx-click="edit_series">Edit</button>
        <button type="button" class="btn btn-sm btn-warning" phx-click="ask_cancel_series">
          Cancel series
        </button>
        <button type="button" class="btn btn-sm btn-error" phx-click="ask_delete_series">
          Delete series
        </button>
      </div>

      <.form
        :if={@editing?}
        for={@form}
        id="series-form"
        phx-submit="save_series"
        class="mb-6 flex flex-wrap items-end gap-2"
      >
        <.input field={@form[:title]} type="text" label="Title" />
        <.input field={@form[:year]} type="number" label="Year" />
        <button class="btn btn-sm btn-primary" type="submit" phx-disable-with="Saving…">Save</button>
        <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit_series">Cancel</button>
      </.form>

      <.confirm_action
        :if={@confirming == :cancel}
        id="confirm-cancel-series"
        on_confirm="confirm_cancel_series"
        on_cancel="dismiss_confirm"
        confirm_label="Cancel series"
        variant="warning"
      >
        <:caveat>Cancel this series? Removes its downloads and unmonitors everything.</:caveat>
      </.confirm_action>

      <div :if={@confirming == :delete} class="mb-6 space-y-2">
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            phx-click="toggle_confirm_opt"
            checked={@confirm_opt}
          />
          <span>Also delete files from disk</span>
        </label>
        <.confirm_action
          id="confirm-delete-series"
          on_confirm="confirm_delete_series"
          on_cancel="dismiss_confirm"
          confirm_label="Delete"
        >
          <:caveat>Delete this series and its seasons/episodes?</:caveat>
        </.confirm_action>
      </div>

      <div class="mb-8 flex gap-4">
        <img
          :if={@series.poster_path}
          src={@poster_base <> @series.poster_path}
          alt={@series.title}
          class="aspect-[2/3] w-24 rounded object-cover"
        />
        <div>
          <.header>
            {@series.title}
            <span :if={@series.year} class="font-normal text-base-content/60">({@series.year})</span>
            <:actions>
              <span class={["badge badge-sm", @series.monitored && "badge-success"]}>
                {if @series.monitored, do: "Monitored", else: "Unmonitored"}
              </span>
            </:actions>
          </.header>
        </div>
      </div>

      <.empty_state
        :if={@series.seasons == []}
        icon="hero-tv"
        title="No seasons found"
        message="TMDB returned no season data for this series."
      />

      <section :for={season <- @series.seasons} class="mb-6">
        <div class="mb-2 flex items-center justify-between border-b border-base-300 pb-2">
          <h2 class="text-lg font-semibold">
            {season_label(season.season_number)}
            <span class="ml-2 text-sm font-normal text-base-content/60">
              {monitored_count(season)}/{length(season.episodes)} monitored
            </span>
          </h2>
          <div class="flex items-center gap-2">
            <button
              :if={season.episodes != []}
              type="button"
              phx-click="toggle_season"
              phx-value-id={season.id}
              class="btn btn-xs"
              aria-label={
                "#{if all_monitored?(season), do: "Unmonitor", else: "Monitor"} all episodes in " <>
                  season_label(season.season_number)
              }
            >
              {if all_monitored?(season), do: "Unmonitor all", else: "Monitor all"}
            </button>
            <button
              :if={Enum.any?(season.episodes, & &1.file_path)}
              type="button"
              class="btn btn-xs btn-error"
              phx-click="ask_delete_season_files"
              phx-value-id={season.id}
              aria-label={"Delete all files in #{season_label(season.season_number)}"}
            >
              Delete files
            </button>
          </div>
        </div>

        <div :if={@confirming == {:season_files, to_string(season.id)}} class="mb-2 space-y-2">
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              phx-click="toggle_confirm_opt"
              checked={@confirm_opt}
            />
            <span>Also stop monitoring these episodes</span>
          </label>
          <.confirm_action
            id={"confirm-delete-season-files-#{season.id}"}
            on_confirm="confirm_delete_season_files"
            on_cancel="dismiss_confirm"
            value={season.id}
            confirm_label="Delete files"
          >
            <:caveat>
              Delete every downloaded file in {season_label(season.season_number)}? Monitored
              episodes will be re-downloaded next sweep unless you also stop monitoring.
            </:caveat>
          </.confirm_action>
        </div>

        <p :if={season.episodes == []} class="text-sm text-base-content/50">No episodes yet.</p>
        <ul class="divide-y divide-base-200">
          <li :for={ep <- season.episodes} class="flex flex-col gap-2 py-2">
            <div class="flex items-center gap-3">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={ep.monitored}
                phx-click="toggle_episode"
                phx-value-id={ep.id}
                aria-label={"Monitor #{season_label(season.season_number)} episode #{ep.episode_number}"}
              />
              <span class="w-8 text-sm tabular-nums text-base-content/60">{ep.episode_number}</span>
              <span class="flex-1 text-sm">{ep.title}</span>
              <span :if={ep.air_date} class="text-xs text-base-content/50">{ep.air_date}</span>
              <button
                :if={ep.file_path}
                type="button"
                class="btn btn-xs btn-error"
                phx-click="ask_delete_episode_file"
                phx-value-id={ep.id}
                aria-label={"Delete file for #{season_label(season.season_number)} episode #{ep.episode_number}"}
              >
                Delete file
              </button>
            </div>
            <div :if={@confirming == {:episode_file, to_string(ep.id)}} class="space-y-2">
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  phx-click="toggle_confirm_opt"
                  checked={@confirm_opt}
                />
                <span>Also stop monitoring this episode</span>
              </label>
              <.confirm_action
                id={"confirm-delete-episode-file-#{ep.id}"}
                on_confirm="confirm_delete_episode_file"
                on_cancel="dismiss_confirm"
                value={ep.id}
                confirm_label="Delete file"
              >
                <:caveat>
                  Delete the downloaded file for this episode? If it stays monitored the poller
                  re-downloads it next tick — tick "stop monitoring" to keep it gone.
                </:caveat>
              </.confirm_action>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp season_label(0), do: "Specials"
  defp season_label(n), do: "Season #{n}"

  defp monitored_count(season), do: Enum.count(season.episodes, & &1.monitored)
end
