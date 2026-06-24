defmodule CinderWeb.SettingsLive do
  @moduledoc """
  In-app configuration for external services, mounted at `/settings`. Values persist
  to the DB (secrets encrypted) and overlay the app env on save. Admin-gated by the
  `:admin` live_session (`CinderWeb.UserAuth.require_admin`); also hosts the
  `auto_approve_all` toggle.

  Secret inputs are never pre-filled — they render empty so a value can't be echoed
  back to the client, even on a re-render. Leave a secret blank to keep it; tick its
  Clear box to remove it. "Test connection" probes the **saved** config, so save first.
  The grouped fields render via `CinderWeb.SettingsComponents` (shared with `/setup`).
  """
  use CinderWeb, :live_view

  import CinderWeb.SettingsComponents

  alias Cinder.{Health, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       form: Settings.form_state(),
       health: %{},
       auto_approve_all: Settings.auto_approve_all?()
     )}
  end

  @impl true
  def handle_event("save", params, socket) do
    Settings.save_form(params)

    {:noreply,
     socket
     |> assign(form: Settings.form_state(), health: %{})
     |> put_flash(:info, "Settings saved.")}
  end

  # Probes the saved config synchronously (each impl health/0 has a ~3s timeout).
  # ponytail: synchronous is fine for an admin-only page; revisit with start_async if
  # the brief block ever annoys.
  def handle_event("test", %{"service" => svc}, socket) do
    case decode_service(svc) do
      nil ->
        {:noreply, socket}

      service ->
        {:noreply,
         assign(socket,
           health: Map.put(socket.assigns.health, svc, Health.check_service(service))
         )}
    end
  end

  @impl true
  def handle_event("toggle_auto_approve", params, socket) do
    on = Map.get(params, "auto_approve_all") == "on"
    Settings.put("auto_approve_all", to_string(on))
    {:noreply, assign(socket, auto_approve_all: on)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Settings
        <:subtitle>
          External services. Stored in the database; secrets encrypted at rest. Save before testing.
        </:subtitle>
      </.header>

      <.link navigate={~p"/status"} class="link mb-6 inline-block">← Status</.link>

      <form id="settings-form" phx-submit="save" class="space-y-8">
        <.service_fields form={@form} health={@health} />
        <button type="submit" class="btn btn-primary">Save settings</button>
      </form>

      <div class="rounded-box bg-base-200 p-4 mt-8">
        <p class="text-lg font-semibold mb-3">Requests</p>
        <form id="auto-approve-form" phx-change="toggle_auto_approve">
          <label class="label cursor-pointer justify-start gap-2">
            <input
              type="checkbox"
              name="auto_approve_all"
              class="toggle"
              checked={@auto_approve_all}
            />
            <span class="label-text">Auto-approve all requests (skip the approval queue)</span>
          </label>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
