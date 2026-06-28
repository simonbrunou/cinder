defmodule CinderWeb.CalendarLive do
  @moduledoc """
  Admin-only upcoming/calendar view at `/calendar`: monitored episodes in a date window
  (`today - 7 .. today + 90`), ordered by air date, each with a derived pipeline-state badge.
  Read-only — subscribes to the `"series"` topic so badges advance live as the poller works.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe_series()
    {:ok, assign_rows(socket)}
  end

  @impl true
  def handle_info({:series_updated, _id}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info({:series_deleted, _id}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_rows(socket) do
    today = Date.utc_today()

    rows =
      for ep <- Catalog.upcoming_episodes() do
        %{ep: ep, state: episode_state(ep, today)}
      end

    assign(socket, rows: rows)
  end

  # Derived episode state (no status enum): a file ⇒ available, an active grab ⇒ downloading,
  # an aired-but-missing monitored episode ⇒ wanted, else still upcoming.
  defp episode_state(ep, today) do
    cond do
      ep.file_path -> :available
      ep.grab_id -> :downloading
      Date.compare(ep.air_date, today) != :gt -> :wanted
      true -> :upcoming
    end
  end

  defp code(season, episode), do: "S#{pad(season)}E#{pad(episode)}"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Upcoming")}
        <:subtitle>{gettext("Monitored episodes airing in the next 90 days.")}</:subtitle>
      </.header>

      <.empty_state
        :if={@rows == []}
        icon="hero-calendar"
        title={gettext("Nothing upcoming")}
        message={gettext("Monitored episodes in the next 90 days will appear here.")}
      />

      <ul :if={@rows != []} id="calendar-list" class="space-y-2">
        <li
          :for={row <- @rows}
          class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-x-3 gap-y-1"
        >
          <time
            datetime={Date.to_iso8601(row.ep.air_date)}
            class="w-24 tabular-nums text-sm text-base-content/70"
          >
            {Calendar.strftime(row.ep.air_date, "%b %-d")}
          </time>
          <.status_badge kind={:episode} status={row.state} />
          <span class="font-medium">{row.ep.season.series.title}</span>
          <span class="tabular-nums text-sm text-base-content/70">
            {code(row.ep.season.season_number, row.ep.episode_number)}
          </span>
          <span class="min-w-0 basis-full truncate text-base-content/70">{row.ep.title}</span>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
