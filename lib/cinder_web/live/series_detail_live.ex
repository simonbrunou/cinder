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
      {:ok, assign(socket, series: series, editing?: false, confirming: nil, form: nil)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Series not found.")
         |> push_navigate(to: ~p"/series")}
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

  def handle_event("ask_cancel_series", _params, socket) do
    {:noreply, assign(socket, confirming: :cancel, editing?: false)}
  end

  def handle_event("ask_delete_series", _params, socket) do
    {:noreply, assign(socket, confirming: :delete, editing?: false)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

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

    case Catalog.delete_series(socket.assigns.series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Series deleted.")
         |> push_navigate(to: ~p"/series")}

      _ ->
        {:noreply,
         socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the series.")}
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
       |> push_navigate(to: ~p"/series")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Guard the series vanishing out from under an open page (no delete path today, but a
  # reload that assigned nil would nil-deref the next render): bounce back to the list.
  defp reload(socket) do
    case Catalog.get_series_with_tree(socket.assigns.series.id) do
      nil -> socket |> put_flash(:error, "Series not found.") |> push_navigate(to: ~p"/series")
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
      <.link navigate={~p"/series"} class="link mb-6 inline-block">← TV series</.link>

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
        <button class="btn btn-sm btn-primary" type="submit">Save</button>
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

      <.confirm_action
        :if={@confirming == :delete}
        id="confirm-delete-series"
        on_confirm="confirm_delete_series"
        on_cancel="dismiss_confirm"
        confirm_label="Delete"
      >
        <:caveat>
          Delete this series and its seasons/episodes? (Library files are left on disk.)
        </:caveat>
      </.confirm_action>

      <div class="mb-8 flex gap-4">
        <img
          :if={@series.poster_path}
          src={@poster_base <> @series.poster_path}
          alt={@series.title}
          class="aspect-[2/3] w-24 rounded object-cover"
        />
        <div>
          <h1 class="text-2xl font-semibold">
            {@series.title}
            <span :if={@series.year} class="font-normal text-base-content/60">
              ({@series.year})
            </span>
          </h1>
          <span class={["badge badge-sm mt-2", @series.monitored && "badge-success"]}>
            {if @series.monitored, do: "monitored", else: "not monitored"}
          </span>
        </div>
      </div>

      <p :if={@series.seasons == []} class="text-base-content/60">
        No seasons found for this series.
      </p>

      <section :for={season <- @series.seasons} class="mb-6">
        <div class="mb-2 flex items-center justify-between border-b border-base-300 pb-2">
          <h2 class="text-lg font-semibold">
            {season_label(season.season_number)}
            <span class="ml-2 text-sm font-normal text-base-content/60">
              {monitored_count(season)}/{length(season.episodes)} monitored
            </span>
          </h2>
          <button
            :if={season.episodes != []}
            type="button"
            phx-click="toggle_season"
            phx-value-id={season.id}
            class="btn btn-xs"
          >
            {if all_monitored?(season), do: "Unmonitor all", else: "Monitor all"}
          </button>
        </div>

        <p :if={season.episodes == []} class="text-sm text-base-content/50">No episodes yet.</p>
        <ul class="divide-y divide-base-200">
          <li :for={ep <- season.episodes} class="flex items-center gap-3 py-2">
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
