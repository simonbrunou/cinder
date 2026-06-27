defmodule CinderWeb.RequestsLive do
  @moduledoc """
  Admin requests screen at `/requests`. Lists every request with a status badge,
  supports approve/deny on pending rows, and a confirm-then-delete on any row.

  Delete warning (intentional, surfaced in the confirm panel): there is no FK
  from a request to the catalog row it spawned, so deleting a request does NOT
  remove an approved movie/series; and deleting a non-pending request re-opens
  the `requests_pending_unique` index, making the title requestable again.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  alias Cinder.Requests

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Requests.subscribe()

    {:ok,
     assign(socket, requests: Requests.list_requests(), denying: nil, confirming_delete: nil)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    req = find_request(socket, id)

    case req && Requests.approve_request(req, socket.assigns.current_scope.user) do
      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't approve that request — please try again.")
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    req = find_request(socket, id)
    if req, do: Requests.deny_request(req, socket.assigns.current_scope.user, reason)
    {:noreply, assign(socket, denying: nil)}
  end

  def handle_event("start_deny", %{"id" => id}, socket) do
    {:noreply, assign(socket, denying: id)}
  end

  def handle_event("start_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_delete: id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming_delete: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    req = find_request(socket, id)

    socket =
      case req && Requests.delete_request(req, socket.assigns.current_scope.user) do
        {:ok, _} -> put_flash(socket, :info, gettext("Request deleted."))
        nil -> socket
        _ -> put_flash(socket, :error, gettext("Couldn't delete that request."))
      end

    {:noreply, assign(socket, confirming_delete: nil, requests: Requests.list_requests())}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _req}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign(socket, requests: Requests.list_requests())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Match a row by its (client-supplied, string) id without raising on garbage input.
  defp find_request(socket, id), do: find_by_id(socket.assigns.requests, id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Requests")}
        <:subtitle>{gettext("Approve, deny, or delete catalog requests.")}</:subtitle>
      </.header>

      <ul :if={@requests != []} class="space-y-3">
        <li
          :for={r <- @requests}
          class="card bg-base-200 p-4 flex flex-col gap-3"
        >
          <div class="flex flex-row items-center gap-4">
            <img
              :if={r.poster_path}
              src={poster_url(r.poster_path, "w92")}
              alt={r.title}
              loading="lazy"
              decoding="async"
              class="w-12 rounded"
            />
            <div class="flex-1">
              <span class="font-semibold">
                {if r.target_type == "season",
                  do:
                    gettext("%{title} — Season %{number}",
                      title: r.title,
                      number: r.season_number
                    ),
                  else: r.title}
              </span>
              <span :if={r.year} class="opacity-60">({r.year})</span>
              <span class="text-sm opacity-60">— {r.user.email}</span>
            </div>
            <.status_badge kind={:request} status={r.status} />
            <.button
              :if={r.status == :pending}
              variant="primary"
              size="sm"
              phx-click="approve"
              phx-value-id={r.id}
              phx-disable-with={gettext("Approving…")}
            >
              {gettext("Approve")}
            </.button>
            <form
              :if={r.status == :pending and @denying == to_string(r.id)}
              phx-submit="deny"
              class="flex gap-2"
            >
              <input type="hidden" name="_id" value={r.id} />
              <input
                type="text"
                name="reason"
                placeholder={gettext("Reason")}
                class="input input-sm input-bordered"
              />
              <.button
                variant="danger"
                size="sm"
                type="submit"
                phx-disable-with={gettext("Denying…")}
              >
                {gettext("Confirm deny")}
              </.button>
            </form>
            <.button
              :if={r.status == :pending and @denying != to_string(r.id)}
              variant="ghost"
              size="sm"
              phx-click="start_deny"
              phx-value-id={r.id}
            >
              {gettext("Deny")}
            </.button>
            <.button
              :if={@confirming_delete != to_string(r.id)}
              variant="ghost"
              size="sm"
              class="text-error"
              phx-click="start_delete"
              phx-value-id={r.id}
            >
              {gettext("Delete")}
            </.button>
          </div>

          <.confirm_action
            :if={@confirming_delete == to_string(r.id)}
            id={"confirm-delete-request-#{r.id}"}
            on_confirm="delete"
            on_cancel="cancel_delete"
            value={r.id}
            confirm_label={gettext("Delete request")}
          >
            <:caveat>
              {gettext(
                "Deleting a request does not remove any movie or series it already created — that catalog row stays. If this request was denied or approved, the same title can be requested again afterwards."
              )}
            </:caveat>
          </.confirm_action>
        </li>
      </ul>
      <.empty_state
        :if={@requests == []}
        icon="hero-inbox-arrow-down"
        title={gettext("No requests")}
        message={gettext("Pending requests will appear here for approval.")}
      />
    </Layouts.app>
    """
  end
end
