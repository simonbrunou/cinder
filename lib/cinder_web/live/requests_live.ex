defmodule CinderWeb.RequestsLive do
  use CinderWeb, :live_view
  alias Cinder.Requests

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Requests.subscribe()
    {:ok, assign(socket, pending: Requests.list_pending(), denying: nil)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    req = Enum.find(socket.assigns.pending, &(to_string(&1.id) == id))
    if req, do: Requests.approve_request(req, socket.assigns.current_scope.user)
    {:noreply, socket}
  end

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    req = Enum.find(socket.assigns.pending, &(to_string(&1.id) == id))
    if req, do: Requests.deny_request(req, socket.assigns.current_scope.user, reason)
    {:noreply, assign(socket, denying: nil)}
  end

  def handle_event("start_deny", %{"id" => id}, socket) do
    {:noreply, assign(socket, denying: id)}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _req}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign(socket, pending: Requests.list_pending())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold mb-4">Pending requests</h1>
      <ul :if={@pending != []} class="space-y-3">
        <li
          :for={r <- @pending}
          class="card bg-base-200 p-4 flex flex-row items-center gap-4"
        >
          <div class="flex-1">
            <span class="font-semibold">{r.title}</span>
            <span :if={r.year} class="opacity-60">({r.year})</span>
            <span class="text-sm opacity-60">— {r.user.email}</span>
          </div>
          <button
            class="btn btn-primary btn-sm"
            phx-click="approve"
            phx-value-id={r.id}
          >
            Approve
          </button>
          <form :if={@denying == to_string(r.id)} phx-submit="deny" class="flex gap-2">
            <input type="hidden" name="_id" value={r.id} />
            <input
              type="text"
              name="reason"
              placeholder="Reason"
              class="input input-sm input-bordered"
            />
            <button class="btn btn-error btn-sm" type="submit">Confirm deny</button>
          </form>
          <button
            :if={@denying != to_string(r.id)}
            class="btn btn-ghost btn-sm"
            phx-click="start_deny"
            phx-value-id={r.id}
          >
            Deny
          </button>
        </li>
      </ul>
      <p :if={@pending == []} class="opacity-60">No pending requests.</p>
    </Layouts.app>
    """
  end
end
