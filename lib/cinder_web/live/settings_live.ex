defmodule CinderWeb.SettingsLive do
  @moduledoc """
  In-app configuration for external services, mounted at `/settings`. Values persist
  to the DB (secrets encrypted) and overlay the app env on save. Admin-gated by the
  `:admin` live_session (`CinderWeb.UserAuth.require_admin`); also hosts the
  `auto_approve_all` toggle and the quality-upgrade sweep's on/off switch (both
  save on change, outside the main form).

  Secret inputs are never pre-filled — they render empty so a value can't be echoed
  back to the client, even on a re-render. Leave a secret blank to keep it; tick its
  Clear box to remove it. "Test connection" probes the **saved** config, so save first.
  The grouped fields render via `CinderWeb.SettingsComponents` (shared with `/setup`).
  """
  use CinderWeb, :live_view

  import CinderWeb.SettingsComponents
  import CinderWeb.LiveHelpers

  alias Cinder.{ApiKey, DatabaseBackup, Health, Settings}
  alias Cinder.Catalog.UpgradeHunter
  alias CinderWeb.SettingsLabels

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       form: Settings.form_state(),
       health: %{},
       form_revision: 0,
       undecryptable_secrets: Settings.undecryptable_secret_keys(),
       auto_approve_all: Settings.auto_approve_all?(),
       upgrade_hunt: UpgradeHunter.enabled?(),
       api_key_set: ApiKey.configured?(),
       # The plaintext key, held for this render only. It is never stored (only its hash is),
       # so once this socket state is replaced it is gone for good.
       new_api_key: nil
     )}
  end

  # A map container is not enough: `save_form/1` raises on a non-binary VALUE too. Drop the frame
  # whole rather than filter it — `plan/1` reads an absent key as an unchecked box
  # (`params[key] || "false"`), so discarding one bad value would turn a crash into a stealth
  # write. This form is submit-only; a `phx-change` here would ship `_target` as a LIST and every
  # change frame would be silently dropped.
  @impl true
  def handle_event("save", params, socket) do
    if settings_params?(params), do: save_settings(params, socket), else: {:noreply, socket}
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

  # `%{} = params` for the same reason as "save" above: `Map.get/2` raises BadMapError on a
  # forged non-map payload.
  @impl true
  def handle_event("toggle_auto_approve", %{} = params, socket) do
    on = Map.get(params, "auto_approve_all") == "on"
    Settings.put("auto_approve_all", to_string(on))
    {:noreply, assign(socket, auto_approve_all: on)}
  end

  # Same `%{} = params` guard as toggle_auto_approve. The assign re-reads the domain predicate
  # rather than the checkbox, so it reflects what the sweep will actually do once the overlay ran.
  def handle_event("toggle_upgrade_hunt", %{} = params, socket) do
    on = Map.get(params, "upgrade_hunt_enabled") == "on"
    Settings.put("upgrade_hunt_enabled", to_string(on))
    {:noreply, assign(socket, upgrade_hunt: UpgradeHunter.enabled?())}
  end

  def handle_event("generate_api_key", _params, socket),
    do: {:noreply, assign(socket, api_key_set: true, new_api_key: ApiKey.generate())}

  def handle_event("revoke_api_key", _params, socket) do
    ApiKey.revoke()
    {:noreply, assign(socket, api_key_set: false, new_api_key: nil)}
  end

  # Event payloads are client-controlled — ignore a forged/unmatched frame rather than
  # crash the LiveView (and lose unsaved form input). House rule; see sibling views.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_settings(params, socket) do
    case Settings.save_form(params) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           form: Settings.form_state(),
           health: %{},
           form_revision: socket.assigns.form_revision + 1,
           undecryptable_secrets: Settings.undecryptable_secret_keys()
         )
         |> put_flash(:info, gettext("Settings saved."))}

      {:error, invalid_keys} ->
        {:noreply,
         socket
         |> assign(form: Settings.form_state(params, invalid_keys))
         |> push_event("focus-invalid", %{id: List.first(invalid_keys)})
         |> put_flash(:error, invalid_band_message(invalid_keys))}
    end
  end

  # Admin sockets are subscribed to the "requests" topic (nav-badge on_mount); ignore those
  # broadcasts here — the on_mount hook already re-renders the badge.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.header>
        {gettext("Settings")}
        <:subtitle>
          {gettext(
            "External service settings are saved in the database. Passwords and API keys are protected. Save before testing a connection."
          )}
        </:subtitle>
      </.header>

      <.link navigate={~p"/dashboard"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Dashboard")}
      </.link>

      <.link
        navigate={~p"/settings/profiles"}
        class="link link-hover mb-6 ml-4 inline-flex items-center gap-1"
      >
        <.icon name="hero-adjustments-horizontal" class="size-3.5" />{gettext("Media profiles")}
      </.link>

      <div
        :if={@undecryptable_secrets != []}
        id="undecryptable-secrets-alert"
        role="alert"
        class="alert alert-error mb-6 items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <div>
          <p class="font-semibold">
            {ngettext(
              "1 stored secret could not be decrypted. The encryption key changed; re-enter it below.",
              "%{count} stored secrets could not be decrypted. The encryption key changed; re-enter them below.",
              length(@undecryptable_secrets)
            )}
          </p>
          <p class="text-sm">
            {gettext("Affected: %{fields}",
              fields:
                Enum.map_join(
                  @undecryptable_secrets,
                  ", ",
                  &SettingsLabels.t(Settings.field_label(&1))
                )
            )}
          </p>
        </div>
      </div>

      <form
        id="settings-form"
        phx-submit="save"
        phx-hook="FormState"
        data-form-revision={@form_revision}
        class="space-y-8"
      >
        <.service_fields form={@form} health={@health} />
        <.button type="submit" phx-disable-with={gettext("Saving…")}>
          {gettext("Save settings")}
        </.button>
      </form>

      <div class="rounded-box bg-base-200 p-4 mt-8">
        <h2 class="text-lg font-semibold mb-3">{gettext("Requests")}</h2>
        <form id="auto-approve-form" phx-change="toggle_auto_approve">
          <label class="label cursor-pointer justify-start gap-2">
            <input
              type="checkbox"
              name="auto_approve_all"
              class="toggle shrink-0"
              checked={@auto_approve_all}
            />
            <span class="label-text">
              {gettext("Auto-approve all requests (skip the approval queue)")}
            </span>
          </label>
          <p
            id="auto-approve-public-warning"
            role="alert"
            class="alert alert-warning mt-3 text-sm"
          >
            {gettext(
              "This also auto-approves requests from anyone who self-registers once their account is approved. Keep it off while registration enrollment is public."
            )}
          </p>
        </form>
      </div>

      <div class="rounded-box bg-base-200 p-4 mt-8">
        <h2 class="text-lg font-semibold mb-3">{gettext("Library upgrades")}</h2>
        <form id="upgrade-hunt-form" phx-change="toggle_upgrade_hunt">
          <label class="label cursor-pointer justify-start gap-2">
            <input
              type="checkbox"
              name="upgrade_hunt_enabled"
              class="toggle shrink-0"
              checked={@upgrade_hunt}
            />
            <span class="label-text">
              {gettext("Look for better releases of titles already in the library")}
            </span>
          </label>
          <p class="text-sm opacity-70 mt-3">
            {gettext(
              "A periodic sweep re-searches the library and, when it finds a better release, downloads it and replaces the file you have. Off by default."
            )}
          </p>
        </form>
      </div>

      <div class="rounded-box bg-base-200 p-4 mt-8">
        <h2 class="text-lg font-semibold mb-3">{gettext("API access")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "A JSON API for dashboard widgets and trusted automation. One key for the whole household, stored hashed, so it can be shown only once. Generating a new key revokes the previous one. Anyone holding the key can read and change the request queue, so treat it as an admin credential."
          )}
        </p>
        <ul class="text-sm mt-2 font-mono">
          <li>{"GET /api/v1/status"}</li>
          <li>{"GET /api/v1/requests"}</li>
          <li>{"POST /api/v1/requests"}</li>
          <li>{"POST /api/v1/requests/:id/approve"}</li>
          <li>{"POST /api/v1/requests/:id/deny"}</li>
          <li>{"DELETE /api/v1/requests/:id"}</li>
        </ul>
        <p class="text-sm mt-2">
          {gettext("Send the key in the %{header} request header.", header: "x-api-key")}
        </p>
        <p class="text-sm opacity-70">
          {gettext(
            "These routes also sit behind the optional HTTP Basic gate, so if you enabled it, API clients must send those credentials too."
          )}
        </p>

        <div
          :if={@new_api_key}
          id="new-api-key"
          role="alert"
          class="alert alert-success mt-3 items-start"
        >
          <div class="min-w-0">
            <p class="font-semibold">{gettext("Copy this key now. It will not be shown again.")}</p>
            <code class="break-all text-sm">{@new_api_key}</code>
          </div>
        </div>

        <p :if={not @api_key_set} class="text-sm mt-3">
          {gettext("No key is set, so the API rejects every request.")}
        </p>

        <div class="mt-3 flex flex-wrap gap-2">
          <%!-- Both controls are destructive once a key exists (regenerating revokes the old
          one just as surely as Revoke does), so both are gated then. A first-time Generate has
          nothing to lose and stays one click. --%>
          <.button
            type="button"
            phx-click="generate_api_key"
            data-confirm={
              @api_key_set &&
                gettext("Regenerate the API key? The current key stops working immediately.")
            }
          >
            {if @api_key_set,
              do: gettext("Regenerate API key"),
              else: gettext("Generate API key")}
          </.button>
          <.button
            :if={@api_key_set}
            type="button"
            variant="danger"
            phx-click="revoke_api_key"
            data-confirm={
              gettext(
                "Revoke the API key? Every dashboard widget and bot using it stops working immediately."
              )
            }
          >
            {gettext("Revoke API key")}
          </.button>
        </div>
      </div>

      <div class="rounded-box bg-base-200 p-4 mt-8">
        <h2 class="text-lg font-semibold mb-3">{gettext("Database backup")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "Download a consistent snapshot of Cinder's database. Keep your SECRET_KEY_BASE with the backup or encrypted settings cannot be restored. Media files are not included."
          )}
        </p>
        <p id="scheduled-database-backups" class="mt-2 text-sm opacity-70">
          {gettext(
            "Automatic verified snapshots run about daily and keep the newest %{count} in %{path}.",
            count: DatabaseBackup.retention(),
            path: DatabaseBackup.backup_dir()
          )}
        </p>
        <.button
          href={~p"/settings/database-backup"}
          download
          variant="neutral"
          class="mt-3"
        >
          {gettext("Download database backup")}
        </.button>
      </div>
    </Layouts.app>
    """
  end
end
