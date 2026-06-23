defmodule CinderWeb.SeriesDiscoveryLive do
  @moduledoc """
  User-facing series discovery at `/series/tmdb/:tmdb_id`.

  Loads season data directly from TMDB (no local series row required) and lets
  any authenticated user request a season. State badges (Pending / Approved /
  Denied) mirror the movie request-button pattern in `WatchlistLive`. No monitor
  toggles — those stay on the admin `/series/:id` page.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Requests

  @poster_base "https://image.tmdb.org/t/p/w342"

  @impl true
  def mount(%{"tmdb_id" => raw}, _session, socket) do
    # The :tmdb_id param is client-controlled; a non-integer must not crash the page.
    with {tmdb_id, ""} <- Integer.parse(raw),
         {:ok, info} <- Catalog.tmdb_series(tmdb_id) do
      if connected?(socket), do: Requests.subscribe()

      user = socket.assigns.current_scope.user

      {:ok,
       socket
       |> assign(tmdb_id: tmdb_id, info: info, current_user: user)
       |> assign_requests_by_season(user, tmdb_id)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Series not found.")
         |> push_navigate(to: ~p"/series")}
    end
  end

  @impl true
  def handle_event("request_season", %{"season" => raw}, socket) do
    case Integer.parse(raw) do
      {season_number, ""} ->
        info = socket.assigns.info
        user = socket.assigns.current_user

        attrs = %{
          target_type: "season",
          target_id: socket.assigns.tmdb_id,
          season_number: season_number,
          title: info.title,
          year: info.year,
          poster_path: info.poster_path
        }

        case Requests.create_request(user, attrs) do
          {:ok, %{status: :approved}} ->
            socket
            |> put_flash(:info, "Season #{season_number} of #{info.title} added.")
            |> refresh_requests()
            |> then(&{:noreply, &1})

          {:ok, %{status: :pending}} ->
            socket
            |> put_flash(
              :info,
              "Season #{season_number} of #{info.title} requested — awaiting approval."
            )
            |> refresh_requests()
            |> then(&{:noreply, &1})

          {:error, :quota_exceeded} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "You've reached your request limit. Wait for approvals to clear."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :info, "Season #{season_number} is already requested.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, refresh_requests(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_requests(socket) do
    assign_requests_by_season(socket, socket.assigns.current_user, socket.assigns.tmdb_id)
  end

  defp assign_requests_by_season(socket, user, tmdb_id) do
    requests_by_season =
      user
      |> Requests.list_for_user()
      |> Enum.filter(&(&1.target_type == "season" and &1.target_id == tmdb_id))
      |> Map.new(&{&1.season_number, &1.status})

    assign(socket, requests_by_season: requests_by_season)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :poster_base, @poster_base)

    ~H"""
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/series"} class="link mb-6 inline-block">← TV series</.link>

      <div class="mb-8 flex gap-4">
        <img
          :if={@info.poster_path}
          src={@poster_base <> @info.poster_path}
          alt={@info.title}
          class="aspect-[2/3] w-24 rounded object-cover"
        />
        <div
          :if={!@info.poster_path}
          class="hidden"
        />
        <div>
          <h1 class="text-2xl font-semibold">
            {@info.title}
            <span :if={@info.year} class="font-normal text-base-content/60">
              ({@info.year})
            </span>
          </h1>
        </div>
      </div>

      <p :if={@info.seasons == []} class="text-base-content/60">
        No seasons found for this series.
      </p>

      <ul class="divide-y divide-base-200">
        <li :for={season <- @info.seasons} class="flex items-center justify-between gap-4 py-3">
          <span class="font-medium">{season_label(season.season_number)}</span>
          <.season_action
            season_number={season.season_number}
            status={@requests_by_season[season.season_number]}
          />
        </li>
      </ul>
    </Layouts.app>
    """
  end

  attr :season_number, :integer, required: true
  attr :status, :atom, default: nil

  defp season_action(assigns) do
    ~H"""
    <span :if={@status != nil} class={["badge badge-sm", badge_class(@status)]}>
      {badge_label(@status)}
    </span>
    <button
      :if={@status == nil}
      type="button"
      phx-click="request_season"
      phx-value-season={@season_number}
      class="btn btn-primary btn-sm"
    >
      Request
    </button>
    """
  end

  defp badge_class(:pending), do: "badge-warning"
  defp badge_class(:approved), do: "badge-info"
  defp badge_class(:denied), do: "badge-error"

  defp badge_label(:pending), do: "Pending"
  defp badge_label(:approved), do: "Approved"
  defp badge_label(:denied), do: "Denied"

  defp season_label(0), do: "Specials"
  defp season_label(n), do: "Season #{n}"
end
