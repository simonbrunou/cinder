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
        {label, class} = badge(ep, today)
        %{ep: ep, label: label, class: class}
      end

    assign(socket, rows: rows)
  end

  # Derived episode state (no status enum): a file ⇒ available, an active grab ⇒ downloading,
  # an aired-but-missing monitored episode ⇒ wanted, else still upcoming.
  defp badge(ep, today) do
    cond do
      ep.file_path -> {"Available", "badge-success"}
      ep.grab_id -> {"Downloading", "badge-info"}
      Date.compare(ep.air_date, today) != :gt -> {"Wanted", "badge-warning"}
      true -> {"Upcoming", "badge-ghost"}
    end
  end

  defp code(season, episode), do: "S#{pad(season)}E#{pad(episode)}"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <h1 class="mb-6 text-2xl font-semibold">Upcoming</h1>

      <p :if={@rows == []} class="text-base-content/60">
        No monitored episodes in the calendar window.
      </p>

      <table :if={@rows != []} class="table">
        <thead>
          <tr>
            <th>Air date</th>
            <th>Series</th>
            <th>Episode</th>
            <th>Title</th>
            <th>State</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="tabular-nums">{row.ep.air_date}</td>
            <td>{row.ep.season.series.title}</td>
            <td class="tabular-nums">{code(row.ep.season.season_number, row.ep.episode_number)}</td>
            <td>{row.ep.title}</td>
            <td><span class={["badge badge-sm", row.class]}>{row.label}</span></td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
