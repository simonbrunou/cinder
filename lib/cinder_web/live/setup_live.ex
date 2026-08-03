defmodule CinderWeb.SetupLive do
  @moduledoc """
  First-run wizard, mounted at `/setup`. The admin is already created (via the normal
  registration flow); this step collects external-service config, validates each via
  `Cinder.Health`, and only lets the admin finish once the loop is fully green — TMDB,
  indexer, a media server, writable movie + TV library paths, and at least one download
  client. Finishing marks `setup_complete`, releasing the `:require_setup` gate.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

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
      {:ok,
       assign(socket,
         form: Settings.form_state(),
         health: %{},
         form_revision: 0,
         can_finish: false
       )}
    end
  end

  # Same guard, same reason, as `CinderWeb.SettingsLive`'s "save" — this is the other caller of
  # `Settings.save_form/1`, and it reaches into the payload's values.
  @impl true
  def handle_event("validate", params, socket) do
    if settings_params?(params), do: validate_settings(params, socket), else: {:noreply, socket}
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

  defp validate_settings(params, socket) do
    case Settings.save_form(params) do
      :ok ->
        health = Map.new(required_services() ++ @download_services, &{&1, check(&1)})

        {:noreply,
         assign(socket,
           form: Settings.form_state(),
           health: health,
           form_revision: socket.assigns.form_revision + 1,
           can_finish: all_green?(health)
         )}

      {:error, invalid_keys} ->
        {:noreply,
         socket
         |> assign(form: Settings.form_state(params, invalid_keys))
         |> push_event("focus-invalid", %{id: List.first(invalid_keys)})
         |> put_flash(:error, invalid_band_message(invalid_keys))}
    end
  end

  defp check(svc), do: Health.check_service(decode_service(svc))

  defp all_green?(health) do
    Enum.all?(required_services(), &(health[&1] == :ok)) and
      Enum.any?(@download_services, &(health[&1] == :ok))
  end

  defp setup_steps do
    [
      %{number: 1, label: gettext("TMDB"), detail: gettext("Add your metadata token.")},
      %{
        number: 2,
        label: gettext("Indexer"),
        detail: gettext("Connect Prowlarr and its indexers.")
      },
      %{
        number: 3,
        label: gettext("Download clients"),
        detail: gettext("Enable qBittorrent or SABnzbd.")
      },
      %{
        number: 4,
        label: gettext("Media server"),
        detail: gettext("Connect Jellyfin or Plex.")
      },
      %{
        number: 5,
        label: gettext("Library paths"),
        detail: gettext("Choose download and library folders.")
      }
    ]
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

      <section
        id="setup-required-steps"
        aria-labelledby="setup-required-steps-title"
        class="mb-8 rounded-box border border-primary/30 bg-primary/10 p-4 sm:p-5"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="badge badge-primary">{gettext("Start here")}</span>
          <h2 id="setup-required-steps-title" class="text-lg font-semibold">
            {gettext("Complete these five required steps in order")}
          </h2>
        </div>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext("The numbered sections are required. Everything marked Optional can wait.")}
        </p>
        <ol class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <li
            :for={step <- setup_steps()}
            id={"setup-step-#{step.number}"}
            class="rounded-box border border-base-300 bg-base-100 p-3"
          >
            <div class="flex items-center gap-2 font-semibold">
              <span class="badge badge-primary badge-sm font-bold">{step.number}</span>
              <span>{step.label}</span>
              <span :if={step.number == 1} class="sr-only">{gettext("Start here")}</span>
            </div>
            <p class="mt-1 text-xs text-base-content/70">{step.detail}</p>
          </li>
        </ol>
      </section>

      <form
        id="setup-form"
        phx-submit="validate"
        phx-hook="FormState"
        data-form-revision={@form_revision}
      >
        <div class="space-y-8">
          <.service_fields
            form={@form}
            health={@health}
            show_move_on_import={false}
            show_anime={false}
            show_setup_guidance={true}
          />
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
        <ul id="setup-checklist" class="space-y-2 text-sm">
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

      <div
        id="setup-notifications-note"
        class="mt-6 rounded-box border border-info/40 bg-info/10 p-4 text-sm"
      >
        <h2 class="mb-1 font-semibold">{gettext("Notifications (optional)")}</h2>
        <p class="text-base-content/80">
          {gettext(
            "Approval, availability, and failure alerts stay off until you add an email (SMTP) or Discord webhook. Set those up in the Notifications section above now, or later in Settings — this step is optional and won't block Finish."
          )}
        </p>
      </div>

      <.button
        id="finish-setup"
        phx-click="finish"
        disabled={not @can_finish}
        phx-disable-with={gettext("Finishing…")}
        class="mt-6"
        aria-describedby="setup-finish-hint"
      >
        {gettext("Finish setup")}
      </.button>
      <p
        :if={not @can_finish}
        id="setup-finish-hint"
        class="mt-2 text-sm text-base-content/70"
      >
        {gettext("Finish unlocks once every required service is connected.")}
      </p>
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
      <div class="min-w-0 break-words">
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
    cond do
      Enum.any?(@download_services, &(health[&1] == :ok)) ->
        :ok

      # validated, but every configured client failed — show red, not the grey "not checked yet"
      Enum.any?(@download_services, &match?({:error, _}, health[&1])) ->
        {:error, :no_download_client}

      true ->
        nil
    end
  end

  defp service_label("tmdb"), do: gettext("TMDB")
  defp service_label("indexer"), do: gettext("Indexer (Prowlarr)")
  defp service_label("media_server"), do: gettext("Media server (Jellyfin/Plex)")
  defp service_label("movies_library"), do: gettext("Movies library path")
  defp service_label("tv_library"), do: gettext("TV library path")
  defp service_label(svc), do: svc |> String.replace("_", " ") |> :string.titlecase()
end
