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
     assign(socket,
       requests: Requests.list_requests(),
       denying: nil,
       confirming_delete: nil,
       selected: MapSet.new()
     )}
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
           gettext("Couldn't approve that request. Please try again.")
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    req = find_request(socket, id)

    # nil (row vanished from under the snapshot) is silent, like the sibling
    # approve/reopen handlers — the broadcast-driven refresh removes it anyway.
    # :not_pending gets a specific message: another admin already decided it, so
    # "try again" would be a lie.
    socket =
      case req && Requests.deny_request(req, socket.assigns.current_scope.user, reason) do
        {:ok, _} ->
          socket

        nil ->
          socket

        {:error, :not_pending} ->
          put_flash(socket, :error, gettext("That request was already decided."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't deny that request. Please try again."))
      end

    {:noreply, assign(socket, denying: nil)}
  end

  def handle_event("start_deny", %{"id" => id}, socket) do
    {:noreply, assign(socket, denying: id)}
  end

  def handle_event("cancel_deny", _params, socket) do
    {:noreply, assign(socket, denying: nil)}
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

  def handle_event("reopen", %{"id" => id}, socket) do
    req = find_request(socket, id)

    socket =
      case req && Requests.reopen_request(req, socket.assigns.current_scope.user) do
        {:ok, _} -> put_flash(socket, :info, gettext("Request reopened."))
        nil -> socket
        _ -> put_flash(socket, :error, gettext("Couldn't reopen that request."))
      end

    {:noreply, assign(socket, requests: Requests.list_requests())}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected: toggle(socket.assigns.selected, id))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new())}
  end

  def handle_event("approve_selected", _params, socket) do
    admin = socket.assigns.current_scope.user
    reqs = selected_pending(socket)

    # Season approvals do blocking TMDB I/O; run the bulk off the LiveView so N seasons can't
    # freeze the page. Each approval broadcasts, so the list refreshes via handle_info — no
    # explicit reload here (that was the redundant double-reload the acting view used to do).
    {:noreply,
     socket
     |> assign(selected: MapSet.new())
     |> start_async(:approve_selected, fn ->
       bulk(reqs, &Requests.approve_request(&1, admin))
     end)}
  end

  def handle_event("deny_selected", %{"reason" => reason}, socket) do
    admin = socket.assigns.current_scope.user
    {ok, failed} = bulk(selected_pending(socket), &Requests.deny_request(&1, admin, reason))
    msg = ngettext("Denied %{count} request.", "Denied %{count} requests.", ok)

    # Deny is DB-only (no I/O); stays synchronous. Drop the explicit reload — deny_request
    # broadcasts, so handle_info refreshes the list.
    {:noreply,
     socket
     |> assign(selected: MapSet.new(), denying: nil)
     |> bulk_flash(msg, ok, failed)}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:approve_selected, {:ok, {ok, failed}}, socket) do
    msg = ngettext("Approved %{count} request.", "Approved %{count} requests.", ok)
    {:noreply, bulk_flash(socket, msg, ok, failed)}
  end

  def handle_async(:approve_selected, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Bulk approve failed. Please try again."))}

  @impl true
  def handle_info({event, _req}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    requests = Requests.list_requests()
    # Drop selections whose rows are no longer pending (e.g. a concurrent admin acted on them),
    # so the "N selected" count and bulk actions stay honest.
    pending = for r <- requests, r.status == :pending, into: MapSet.new(), do: to_string(r.id)
    selected = MapSet.intersection(socket.assigns.selected, pending)
    {:noreply, assign(socket, requests: requests, selected: selected)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Match a row by its (client-supplied, string) id without raising on garbage input.
  defp find_request(socket, id), do: find_by_id(socket.assigns.requests, id)

  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  # Selected, still-pending requests (drops any a concurrent admin already acted on).
  defp selected_pending(socket) do
    selected = socket.assigns.selected

    Enum.filter(
      socket.assigns.requests,
      &(&1.status == :pending and MapSet.member?(selected, to_string(&1.id)))
    )
  end

  # Apply `fun` to each request; tally {ok, failed}.
  defp bulk(reqs, fun) do
    Enum.reduce(reqs, {0, 0}, fn req, {ok, failed} ->
      case fun.(req) do
        {:ok, _} -> {ok + 1, failed}
        _ -> {ok, failed + 1}
      end
    end)
  end

  defp bulk_flash(socket, _msg, 0, _failed),
    do: put_flash(socket, :error, gettext("Nothing was updated."))

  defp bulk_flash(socket, msg, _ok, 0), do: put_flash(socket, :info, msg)

  defp bulk_flash(socket, msg, _ok, failed),
    do:
      put_flash(
        socket,
        :warning,
        msg <> " " <> ngettext("%{count} request failed.", "%{count} requests failed.", failed)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Requests")}
        <:subtitle>{gettext("Approve, deny, or delete catalog requests.")}</:subtitle>
      </.header>

      <div
        :if={MapSet.size(@selected) > 0}
        class="mb-4 flex flex-wrap items-center gap-3 rounded-box border border-base-300 bg-base-200 p-3"
      >
        <span class="text-sm font-medium">
          {gettext("%{count} selected", count: MapSet.size(@selected))}
        </span>
        <.button size="sm" phx-click="approve_selected" phx-disable-with={gettext("Approving…")}>
          {gettext("Approve selected")}
        </.button>
        <.deny_form
          event="deny_selected"
          reason_label={gettext("Denial reason for the selected requests")}
          submit_label={gettext("Deny selected")}
          class="flex-1"
        />
        <.button variant="ghost" size="sm" type="button" phx-click="clear_selection">
          {gettext("Clear")}
        </.button>
      </div>

      <ul :if={@requests != []} class="space-y-3">
        <li
          :for={r <- @requests}
          class="rounded-box bg-base-200/50 p-4 flex flex-col gap-3"
        >
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <input
              :if={r.status == :pending}
              type="checkbox"
              class="checkbox checkbox-sm"
              phx-click="toggle_select"
              phx-value-id={r.id}
              checked={MapSet.member?(@selected, to_string(r.id))}
              aria-label={gettext("Select the request for %{title}", title: r.title)}
            />
            <img
              :if={r.poster_path}
              src={poster_url(r.poster_path, "w92")}
              alt={r.title}
              loading="lazy"
              decoding="async"
              class="w-12 rounded"
            />
            <div class="min-w-0 flex-1">
              <span class="font-semibold">
                {if r.target_type == "season",
                  do:
                    gettext("%{title}: Season %{number}",
                      title: r.title,
                      number: r.season_number
                    ),
                  else: r.title}
              </span>
              <span :if={r.year} class="opacity-70">({r.year})</span>
              <span class="block truncate text-sm opacity-70">{r.user.email}</span>
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
            <.deny_form
              :if={r.status == :pending and @denying == to_string(r.id)}
              event="deny"
              id={r.id}
              reason_label={gettext("Denial reason")}
              submit_label={gettext("Confirm deny")}
              on_cancel="cancel_deny"
            />
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
              :if={r.status == :denied}
              variant="ghost"
              size="sm"
              phx-click="reopen"
              phx-value-id={r.id}
              phx-disable-with={gettext("Reopening…")}
            >
              {gettext("Reopen")}
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
                "Deleting a request does not remove any movie or series it already created; that catalog row stays. If this request was denied or approved, the same title can be requested again afterwards."
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
