defmodule CinderWeb.SetupLive do
  @moduledoc """
  First-run wizard, mounted at `/setup`. The admin is already created (via the normal
  registration flow); this step collects external-service config, validates each via
  `Cinder.Health`, and only lets the admin finish once the loop is fully green: every probe
  target with `setup: :required` (TMDB, the indexer, the media server, a writable root for every
  library kind) and at least one target of each `setup: :any` group (a download client).
  Finishing marks `setup_complete`, releasing the `:require_setup` gate.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  import CinderWeb.SettingsComponents

  alias Cinder.{Health, Settings}
  alias CinderWeb.SettingsLabels

  # Every probe target the gate reads, checked on "Save & validate".
  defp setup_targets, do: Health.targets(setup: :required) ++ Health.targets(setup: :any)

  # The `:any` targets, one list per group (targets are listed in group order).
  defp any_groups, do: Enum.chunk_by(Health.targets(setup: :any), & &1.group)

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

  # Per-target Test buttons (rendered by the shared SettingsComponents) probe one target against
  # the saved config and refresh the green/red badge + the Finish gate. The id is
  # client-controlled; one no probe target has changes nothing.
  def handle_event("test", %{"target" => id}, socket) do
    case Health.check(id) do
      {:error, :unknown_target} ->
        {:noreply, socket}

      status ->
        health = Map.put(socket.assigns.health, id, reachable(status))
        {:noreply, assign(socket, health: health, can_finish: all_green?(health))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp validate_settings(params, socket) do
    case Settings.save_form(params) do
      :ok ->
        health =
          Map.new(Health.check_targets(setup_targets()), fn {id, status} ->
            {id, reachable(status)}
          end)

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

  defp reachable({:warning, _reason}), do: :ok
  defp reachable(status), do: status

  defp all_green?(health) do
    Enum.all?(Health.targets(setup: :required), &(health[&1.id] == :ok)) and
      Enum.all?(any_groups(), &(any_status(&1, health) == :ok))
  end

  # A `:any` group passes once one of its targets is reachable.
  defp any_status(targets, health) do
    cond do
      Enum.any?(targets, &(health[&1.id] == :ok)) -> :ok
      # validated, but every checked target failed — show red, not the grey "not checked yet"
      Enum.any?(targets, &match?({:error, _}, health[&1.id])) -> {:error, :none_reachable}
      true -> nil
    end
  end

  # One line per required target, then one per `:any` group, named after the group. Target ids
  # and group names are separate keyspaces, so the two kinds of row take separate DOM id prefixes.
  defp checklist(health) do
    required =
      for target <- Health.targets(setup: :required) do
        %{
          id: "setup-check-#{target.id}",
          label: SettingsLabels.t(target.label),
          status: health[target.id],
          hint: nil
        }
      end

    any =
      for [%{group: group} | _] = targets <- any_groups() do
        %{
          id: "setup-check-group-#{group}",
          label: SettingsLabels.t(Keyword.fetch!(Settings.groups(), group)),
          status: any_status(targets, health),
          hint: gettext("connect at least one")
        }
      end

    required ++ any
  end

  defp setup_steps do
    for {{group, label}, number} <- Enum.with_index(setup_groups(), 1),
        do: %{number: number, label: SettingsLabels.t(label), detail: step_detail(group)}
  end

  defp step_detail(:tmdb), do: gettext("Add your metadata token.")
  defp step_detail(:indexer), do: gettext("Connect Prowlarr and its indexers.")
  defp step_detail(:download), do: gettext("Choose a torrent or Usenet client.")
  defp step_detail(:media_server), do: gettext("Connect Jellyfin or Plex.")
  defp step_detail(:library), do: gettext("Choose download and library folders.")
  defp step_detail(_group), do: nil

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
            {ngettext(
              "Complete this required step",
              "Complete these %{count} required steps in order",
              length(setup_groups())
            )}
          </h2>
        </div>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext("The numbered sections are required. Everything marked Optional can wait.")}
        </p>
        <%!-- One row of equal columns at xl, however many steps there are. --%>
        <ol class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-flow-col xl:grid-cols-none xl:auto-cols-fr">
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
            <p :if={step.detail} class="mt-1 text-xs text-base-content/70">{step.detail}</p>
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
            :for={row <- checklist(@health)}
            id={row.id}
            label={row.label}
            status={row.status}
            hint={row.hint}
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
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :status, :any, default: nil
  attr :hint, :string, default: nil

  defp check_row(assigns) do
    ~H"""
    <li id={@id} class="flex items-start gap-2">
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
end
