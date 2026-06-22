defmodule CinderWeb.SettingsLive do
  @moduledoc """
  In-app configuration for external services, mounted at `/settings`. Values persist
  to the DB (secrets encrypted) and overlay the app env on save. Admin-gated by the
  `:admin` live_session (`CinderWeb.UserAuth.require_admin`); also hosts the
  `auto_approve_all` toggle.

  Secret inputs are never pre-filled — they render empty so a value can't be echoed
  back to the client, even on a re-render. Leave a secret blank to keep it; tick its
  Clear box to remove it. "Test connection" probes the **saved** config, so save first.
  """
  use CinderWeb, :live_view

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

  # phx-value is client-controlled; only known services resolve.
  defp decode_service("tmdb"), do: :tmdb
  defp decode_service("indexer"), do: :indexer
  defp decode_service("media_server"), do: :media_server
  defp decode_service("torrent"), do: {:download, :torrent}
  defp decode_service("usenet"), do: {:download, :usenet}
  defp decode_service("library"), do: :library
  defp decode_service(_other), do: nil

  defp services_for(:tmdb), do: [{"tmdb", "TMDB"}]
  defp services_for(:indexer), do: [{"indexer", "Prowlarr"}]
  defp services_for(:download), do: [{"torrent", "qBittorrent"}, {"usenet", "SABnzbd"}]
  defp services_for(:media_server), do: [{"media_server", "Media server"}]
  defp services_for(:library), do: [{"library", "Library path"}]
  defp services_for(_group), do: []

  defp secret_placeholder(field, secrets_set) do
    if MapSet.member?(secrets_set, field.key),
      do: "•••• saved (leave blank to keep)",
      else: ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Settings
        <:subtitle>
          External services. Stored in the database; secrets encrypted at rest. Save before testing.
        </:subtitle>
      </.header>

      <.link navigate={~p"/status"} class="link mb-6 inline-block">← Status</.link>

      <form id="settings-form" phx-submit="save" class="space-y-8">
        <fieldset :for={{group, label} <- Settings.groups()} class="rounded-box bg-base-200 p-4">
          <legend class="px-2 text-lg font-semibold">{label}</legend>

          <div :if={group == :media_server} class="form-control mb-2">
            <label class="label" for="media_server_type">
              <span class="label-text">Media server type</span>
            </label>
            <select id="media_server_type" name="media_server_type" class="select w-full">
              <option
                :for={opt <- Settings.media_server_options()}
                value={opt}
                selected={@form.values[Settings.media_server_key()] == opt}
              >
                {opt}
              </option>
            </select>
          </div>

          <div :if={group == :download} class="mb-3">
            <label :for={t <- Settings.toggles()} class="label cursor-pointer justify-start gap-2">
              <input type="hidden" name={t.key} value="false" />
              <input
                type="checkbox"
                name={t.key}
                value="true"
                checked={@form.values[t.key]}
                class="checkbox"
              />
              <span class="label-text">{t.label}</span>
            </label>
          </div>

          <div :if={group == :library} class="form-control mb-2">
            <label class="label" for="library_path">
              <span class="label-text">Library path (where movies are hardlinked)</span>
            </label>
            <input
              type="text"
              id="library_path"
              name="library_path"
              value={@form.values[Settings.library_path_key()]}
              placeholder="/media/movies"
              autocomplete="off"
              class="input w-full"
            />
          </div>

          <.setting_field :for={field <- Settings.config_fields(group)} field={field} form={@form} />

          <div class="mt-3 flex flex-wrap items-center gap-3">
            <div :for={{svc, svc_label} <- services_for(group)} class="flex items-center gap-2">
              <button type="button" class="btn btn-xs" phx-click="test" phx-value-service={svc}>
                Test {svc_label}
              </button>
              <.test_badge :if={@health[svc]} result={@health[svc]} />
            </div>
          </div>
        </fieldset>

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

  attr :field, :map, required: true
  attr :form, :map, required: true

  defp setting_field(assigns) do
    ~H"""
    <div class="form-control mb-2">
      <label class="label" for={@field.key}>
        <span class="label-text">{@field.label}</span>
      </label>

      <input
        :if={not @field.secret}
        type="text"
        id={@field.key}
        name={@field.key}
        value={@form.values[@field.key]}
        placeholder={@field.placeholder}
        autocomplete="off"
        class="input w-full"
      />

      <div :if={@field.secret}>
        <input
          type="password"
          id={@field.key}
          name={@field.key}
          value=""
          placeholder={secret_placeholder(@field, @form.secrets_set)}
          autocomplete="off"
          class="input w-full"
        />
        <label class="label mt-1 cursor-pointer justify-start gap-2">
          <input type="checkbox" name={"clear_" <> @field.key} class="checkbox checkbox-sm" />
          <span class="label-text">Clear saved value</span>
        </label>
      </div>
    </div>
    """
  end

  attr :result, :any, required: true

  defp test_badge(assigns) do
    ~H"""
    <span
      class={["badge badge-sm", if(@result == :ok, do: "badge-success", else: "badge-error")]}
      title={test_title(@result)}
    >
      {if @result == :ok, do: "ok", else: "unreachable"}
    </span>
    """
  end

  # Surface the (sanitized) failure reason so a bad credential shows e.g. {:tmdb_status, 401}
  # rather than a bare "unreachable", mirroring StatusLive.
  defp test_title(:ok), do: nil
  defp test_title({:error, reason}), do: inspect(reason)
  defp test_title(_other), do: nil
end
