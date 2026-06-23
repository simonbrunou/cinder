defmodule CinderWeb.SetupLive do
  @moduledoc """
  First-run wizard, mounted at `/setup`. The admin is already created (via the normal
  registration flow); this step collects external-service config, validates each via
  `Cinder.Health`, and only lets the admin finish once the loop is fully green — TMDB,
  indexer, a media server, writable movie + TV library paths, and at least one download
  client. Finishing marks `setup_complete`, releasing the `:require_setup` gate.
  """
  use CinderWeb, :live_view

  import CinderWeb.SettingsComponents

  alias Cinder.{Health, Settings}

  @required_services ["tmdb", "indexer", "media_server", "library", "tv_library"]
  @download_services ["torrent", "usenet"]

  @impl true
  def mount(_params, _session, socket) do
    if Settings.setup_complete?() do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok, assign(socket, form: Settings.form_state(), health: %{}, can_finish: false)}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    Settings.save_form(params)
    health = Map.new(@required_services ++ @download_services, &{&1, check(&1)})

    {:noreply,
     assign(socket, form: Settings.form_state(), health: health, can_finish: all_green?(health))}
  end

  def handle_event("finish", _params, socket) do
    if socket.assigns.can_finish do
      Settings.mark_setup_complete()
      {:noreply, push_navigate(socket, to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  # Per-service Test buttons (rendered by the shared SettingsComponents) probe one
  # saved service and refresh the green/red badge + the Finish gate.
  def handle_event("test", %{"service" => svc}, socket) do
    case decode_service(svc) do
      nil ->
        {:noreply, socket}

      service ->
        health = Map.put(socket.assigns.health, svc, Health.check_service(service))
        {:noreply, assign(socket, health: health, can_finish: all_green?(health))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp check(svc), do: Health.check_service(decode_service(svc))

  defp all_green?(health) do
    Enum.all?(@required_services, &(health[&1] == :ok)) and
      Enum.any?(@download_services, &(health[&1] == :ok))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Set up Cinder
        <:subtitle>
          Enter and validate your services. Finish unlocks once the movie loop is green.
        </:subtitle>
      </.header>

      <form id="setup-form" phx-submit="validate">
        <div class="space-y-8">
          <.service_fields form={@form} health={@health} />
        </div>
        <button type="submit" class="btn btn-primary mt-4">Save &amp; validate</button>
      </form>

      <button
        id="finish-setup"
        phx-click="finish"
        disabled={not @can_finish}
        class="btn btn-success mt-6"
      >
        Finish setup
      </button>
    </Layouts.app>
    """
  end
end
