defmodule CinderWeb.GrabsLive do
  @moduledoc """
  Admin grab list at `/grabs`: every in-flight download newest-first, with its derived series and
  episodes and a download-vs-downloaded status, plus an in-LiveView delete confirm. Grabs are
  created by the pipeline only (no create path). Admin-gated by the `:admin` live_session.
  Subscribes to the `"series"` topic so a grab created/finished elsewhere keeps the list live.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe_series()
    {:ok, assign(socket, grabs: Catalog.list_grabs(), confirming: nil)}
  end

  @impl true
  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: id)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    grab = Enum.find(socket.assigns.grabs, &(to_string(&1.id) == id))

    if grab, do: Catalog.delete_grab(grab)

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(:info, "Grab deleted.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:series_updated, _id}, socket) do
    {:noreply, assign(socket, grabs: Catalog.list_grabs())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_grab), do: "—"

  defp grab_state(%{content_path: nil}), do: :downloading
  defp grab_state(_grab), do: :downloaded

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Grabs<:subtitle>In-flight downloads, newest first.</:subtitle>
      </.header>

      <p :if={@grabs == []} class="text-base-content/60">No grabs.</p>

      <ul class="space-y-3">
        <li :for={g <- @grabs} id={"grab-#{g.id}"} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{series_title(g)}</span>
            <.status_badge kind={:grab} status={grab_state(g)} />
            <span class="text-sm text-base-content/60">{g.download_protocol}</span>
            <span class="text-xs text-base-content/50">{g.download_id}</span>

            <button
              type="button"
              class="btn btn-xs btn-error ml-auto"
              phx-click="ask_delete"
              phx-value-id={g.id}
            >
              Delete
            </button>
          </div>

          <.confirm_action
            :if={@confirming == to_string(g.id)}
            id={"confirm-delete-grab-#{g.id}"}
            on_confirm="confirm_delete"
            on_cancel="dismiss_confirm"
            value={g.id}
            confirm_label="Delete"
          >
            <:caveat>Delete this grab? Its episodes are unlinked.</:caveat>
          </.confirm_action>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
