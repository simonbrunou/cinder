defmodule CinderWeb.MyRequestsLive do
  @moduledoc """
  A requester's own requests, mounted at `/my-requests`. Shows each request's status
  (pending/approved/denied) and, once approved, the movie's live pipeline state
  (→ Available). Live via the `"requests"` and `"movies"` PubSub topics.
  """
  use CinderWeb, :live_view

  alias Cinder.{Catalog, Requests}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      Catalog.subscribe()
    end

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    user = socket.assigns.current_scope.user
    movie_status = Map.new(Catalog.list_watchlist(), &{&1.tmdb_id, &1.status})

    assign(socket, requests: Requests.list_for_user(user), movie_status: movie_status)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        My requests<:subtitle>Track what you've asked for.</:subtitle>
      </.header>

      <p :if={@requests == []} class="text-base-content/60">You haven't requested anything yet.</p>

      <ul id="my-requests" class="space-y-3">
        <li :for={r <- @requests} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{r.title}</span>
            <span :if={r.year} class="text-base-content/60">({r.year})</span>
            <.request_status_badge status={r.status} />
            <.movie_status_badge :if={@movie_status[r.target_id]} status={@movie_status[r.target_id]} />
          </div>
          <p :if={r.status == :denied and r.denial_reason} class="mt-1 text-sm text-error">
            {r.denial_reason}
          </p>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
