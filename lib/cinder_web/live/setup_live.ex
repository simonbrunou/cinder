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

  @base_required_services ["tmdb", "indexer", "media_server"]
  @download_services ["torrent", "usenet"]

  # The required set is the base services plus one writable-root check per library kind
  # (`movies_library`, `tv_library`, …), derived from Settings.library_kinds/0.
  defp required_services do
    @base_required_services ++
      for(%{kind: kind} <- Settings.library_kinds(), do: "#{kind}_library")
  end

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
    health = Map.new(required_services() ++ @download_services, &{&1, check(&1)})

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
    Enum.all?(required_services(), &(health[&1] == :ok)) and
      Enum.any?(@download_services, &(health[&1] == :ok))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {gettext("Set up Cinder")}
        <:subtitle>
          {gettext(
            "Enter and validate your services. Finish unlocks once every required service is connected."
          )}
        </:subtitle>
      </.header>

      <form id="setup-form" phx-submit="validate">
        <div class="space-y-8">
          <.service_fields form={@form} health={@health} show_move_on_import={false} />
        </div>
        <.button
          type="submit"
          variant="neutral"
          class="mt-4"
          phx-disable-with={gettext("Validating…")}
        >
          {gettext("Save & validate")}
        </.button>
      </form>

      <div class="mt-6 rounded-box border border-base-300 bg-base-200 p-4">
        <h2 class="mb-3 text-lg font-semibold">{gettext("Setup checklist")}</h2>
        <ul class="space-y-2 text-sm">
          <.check_row
            :for={svc <- required_services()}
            label={service_label(svc)}
            status={@health[svc]}
          />
          <.check_row
            label={gettext("A download client (torrent or usenet)")}
            status={download_status(@health)}
            hint={gettext("connect at least one")}
          />
        </ul>
      </div>

      <.button
        id="finish-setup"
        phx-click="finish"
        disabled={not @can_finish}
        phx-disable-with={gettext("Finishing…")}
        class="mt-6"
      >
        {gettext("Finish setup")}
      </.button>
    </Layouts.app>
    """
  end

  # One checklist line: a green check when the service is reachable, a red x with
  # the reason when it failed, or a grey hint when it has not been validated yet.
  attr :label, :string, required: true
  attr :status, :any, default: nil
  attr :hint, :string, default: nil

  defp check_row(assigns) do
    ~H"""
    <li class="flex items-start gap-2">
      <.icon name={check_icon(@status)} class={["mt-0.5 size-4 shrink-0", check_color(@status)]} />
      <div>
        <span>{@label}</span>
        <span :if={match?({:error, _}, @status)} class="text-error">
          ({health_reason(elem(@status, 1))})
        </span>
        <span :if={is_nil(@status)} class="text-base-content/70">
          ({@hint || gettext("not checked yet")})
        </span>
      </div>
    </li>
    """
  end

  defp check_icon(:ok), do: "hero-check-circle"
  defp check_icon({:error, _}), do: "hero-x-circle"
  defp check_icon(_), do: "hero-minus-circle"

  defp check_color(:ok), do: "text-success"
  defp check_color({:error, _}), do: "text-error"
  defp check_color(_), do: "text-base-content/40"

  # The download requirement is "at least one of torrent/usenet reachable".
  defp download_status(health) do
    if Enum.any?(@download_services, &(health[&1] == :ok)), do: :ok
  end

  defp service_label("tmdb"), do: gettext("TMDB")
  defp service_label("indexer"), do: gettext("Indexer (Prowlarr)")
  defp service_label("media_server"), do: gettext("Media server (Jellyfin/Plex)")
  defp service_label("movies_library"), do: gettext("Movies library path")
  defp service_label("tv_library"), do: gettext("TV library path")
  defp service_label(svc), do: svc |> String.replace("_", " ") |> :string.titlecase()
end
