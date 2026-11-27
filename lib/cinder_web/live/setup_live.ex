defmodule CinderWeb.SetupLive do
  @moduledoc """
  First-run wizard, mounted at `/setup`. The admin is already created (via the normal
  registration flow); this step collects external-service config, validates each via
  `Cinder.Health`, and only lets the admin finish once every requirement passes: every probe
  target with `setup: :required` (TMDB, the indexer, the media server, a writable root for every
  library kind) and at least one target of each `setup: :any` group (a download client). A
  target passes when its last check answered `:ok` or `{:warning, reason}`; the checklist shows a
  warning yellow with its reason. Finishing marks `setup_complete`, releasing the
  `:require_setup` gate.

  Step 2, the Indexers group, holds the "Indexer source" select and the indexers table
  (`CinderWeb.IndexersComponent`), as on `/settings`. "Save & validate" stores the source with
  the other fields and refuses no switch (#1663): on Built-in the gate blocks Finish instead.
  While the running source is `Cinder.Acquisition.IndexerSource.Native`, the indexer requirement
  reads the saved indexer states, never a request, at one reading of Native's clock:

  - it fails, red with the source's reason (`IndexerState.health/2`), while no indexer passes
    `IndexerState.passes?/1`;
  - it passes green when one does and the source's health is `:ok`, else yellow with that
    health's reason, which is the case when the only passing indexers wait out a limit;
  - once some download client passed its last check, it also needs a passing indexer of a
    protocol that some client which passed uses, and shows red "No usable indexer uses the same
    protocol as a working download client." without one. Prowlarr gets no such check.

  The page recomputes the gate, with no request, on each host notice the indexers table sends
  (`{CinderWeb.IndexersComponent, :indexers_changed}`, after a saved add or edit, enable switch
  and Delete, a finished Test, a backoff's end and the refresh after each saved form), and again
  on `finish`, from the saved indexer states and the latest check of every other target, before
  it marks setup complete. On Prowlarr the indexer requirement stays the latest live probe.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers

  import CinderWeb.SettingsComponents

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, TestRunner}
  alias Cinder.{Health, Settings}
  alias Cinder.Indexers.Definitions.Updater
  alias CinderWeb.{DomainLabels, IndexersComponent}

  # Every probe target the gate reads, checked on "Save & validate".
  defp setup_targets, do: Health.targets(setup: :required) ++ Health.targets(setup: :any)

  # The `:any` targets, one list per group (targets are listed in group order).
  defp any_groups, do: Enum.chunk_by(Health.targets(setup: :any), & &1.group)

  @impl true
  def mount(_params, _session, socket) do
    if Settings.setup_complete?() do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      # Before the indexers table first reads which Tests run and whether a definitions update
      # runs, so no finish falls between the read and the subscription.
      if connected?(socket) do
        TestRunner.subscribe()
        Updater.subscribe()
      end

      {:ok,
       socket
       |> assign(
         form: Settings.form_state(),
         indexer_source: indexer_source_state(),
         form_revision: 0
       )
       |> assign_gate(%{})}
    end
  end

  # Same guard, same reason, as `CinderWeb.SettingsLive`'s "save" — this is the other caller of
  # `Settings.save_form/1`, and it reaches into the payload's values.
  @impl true
  def handle_event("validate", params, socket) do
    if settings_params?(params), do: validate_settings(params, socket), else: {:noreply, socket}
  end

  # The gate is recomputed here, so a forged event or a page whose indexers changed since its
  # last recompute finishes only on what is saved now.
  def handle_event("finish", _params, socket) do
    socket = assign_gate(socket, socket.assigns.health)

    if socket.assigns.can_finish do
      Settings.mark_setup_complete()
      {:noreply, push_navigate(socket, to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  # Per-target Test buttons (rendered by the shared SettingsComponents) probe one target against
  # the saved config and refresh the badge + the Finish gate. The id is client-controlled; one no
  # probe target has changes nothing.
  def handle_event("test", %{"target" => id}, socket) do
    case Health.check(id) do
      {:error, :unknown_target} ->
        {:noreply, socket}

      status ->
        {:noreply, assign_gate(socket, Map.put(socket.assigns.health, id, status))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The per-indexer Test runner's start and finish messages go to the indexers table, as on
  # `/settings`.
  @impl true
  def handle_info(message, socket) when is_tuple(message) and elem(message, 0) == TestRunner do
    send_update(IndexersComponent, id: "indexers", runner: message)
    {:noreply, socket}
  end

  # The end of a definitions update run goes to the indexers table's definitions line (#1676).
  def handle_info({:definitions_update, outcome}, socket) do
    send_update(IndexersComponent, id: "indexers", definitions_update: outcome)
    {:noreply, socket}
  end

  # On Built-in the Indexers check (`Native.health/0`) reads the saved indexers' states and sends
  # no request, so a check the page shows is read again on the same changes as the row. Prowlarr's
  # check reads no saved indexer and stays as its last Test or save left it.
  def handle_info({IndexersComponent, :indexers_changed}, socket) do
    health = socket.assigns.health

    health =
      if Map.has_key?(health, "indexer") and IndexerSource.configured() == Native,
        do: Map.put(health, "indexer", Health.check("indexer")),
        else: health

    {:noreply, assign_gate(socket, health)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp validate_settings(params, socket) do
    case Settings.save_form(params) do
      :ok ->
        # The indexers table reads the saved source for Delete's warning on each read of its rows.
        send_update(IndexersComponent, id: "indexers", refresh: true)

        {:noreply,
         socket
         |> assign(
           form: Settings.form_state(),
           indexer_source: indexer_source_state(),
           form_revision: socket.assigns.form_revision + 1
         )
         |> assign_gate(Health.check_targets(setup_targets()))}

      {:error, invalid_keys} ->
        {:noreply,
         socket
         |> assign(form: Settings.form_state(params, invalid_keys))
         |> push_event("focus-invalid", %{id: List.first(invalid_keys)})
         |> put_flash(:error, invalid_band_message(invalid_keys))}
    end
  end

  # `health` holds each target's last check as it answered, for the Test badges. The gate reads
  # `statuses`, the same map with the indexer's requirement in place of its check on Built-in.
  defp assign_gate(socket, health) do
    statuses = Map.put(health, "indexer", indexer_requirement(health))
    assign(socket, health: health, statuses: statuses, can_finish: all_passing?(statuses))
  end

  defp indexer_requirement(health) do
    if IndexerSource.configured() == Native,
      do: native_requirement(health),
      else: health["indexer"]
  end

  # One read of the saved states, judged at one instant, for the gate, the reason and the
  # protocols. With no indexer passing, `IndexerState.health/2` is an error.
  defp native_requirement(health) do
    now = Native.now()
    entries = IndexerState.list(now)
    passing = Enum.filter(entries, &IndexerState.passes?/1)

    cond do
      passing == [] -> IndexerState.health(entries, now)
      not covers_a_working_client?(passing, health) -> {:error, :no_protocol_match}
      true -> passing_level(IndexerState.health(entries, now))
    end
  end

  # Silent, so true, until some download client passed its last check.
  defp covers_a_working_client?(passing, health) do
    working =
      for %{probe: {:download, protocol}} = target <- Health.targets(group: :download),
          passing?(health[target.id]),
          do: protocol

    working == [] or Enum.any?(passing, &(&1.protocol in working))
  end

  # The gate passed, so a source that is not `:ok` reads as a warning with its reason.
  defp passing_level(:ok), do: :ok
  defp passing_level({_level, reason}), do: {:warning, reason}

  defp passing?(:ok), do: true
  defp passing?({:warning, _reason}), do: true
  defp passing?(_status), do: false

  defp all_passing?(statuses) do
    Enum.all?(Health.targets(setup: :required), &passing?(statuses[&1.id])) and
      Enum.all?(any_groups(), &passing?(any_status(&1, statuses)))
  end

  # A `:any` group passes once one of its targets passes: green when every passing target is
  # `:ok`, yellow with the first passing target's warning otherwise.
  defp any_status(targets, statuses) do
    passing = for target <- targets, passing?(statuses[target.id]), do: statuses[target.id]

    cond do
      passing != [] -> Enum.find(passing, :ok, &match?({:warning, _reason}, &1))
      # validated, but every checked target failed — show red, not the grey "not checked yet"
      Enum.any?(targets, &match?({:error, _}, statuses[&1.id])) -> {:error, :none_reachable}
      true -> nil
    end
  end

  # One line per required target, then one per `:any` group, named after the group. Target ids
  # and group names are separate keyspaces, so the two kinds of row take separate DOM id prefixes.
  defp checklist(statuses) do
    required =
      for target <- Health.targets(setup: :required) do
        %{
          id: "setup-check-#{target.id}",
          label: DomainLabels.t(target.label),
          status: statuses[target.id],
          hint: nil
        }
      end

    any =
      for [%{group: group} | _] = targets <- any_groups() do
        %{
          id: "setup-check-group-#{group}",
          label: DomainLabels.t(Keyword.fetch!(Settings.groups(), group)),
          status: any_status(targets, statuses),
          hint: gettext("connect at least one")
        }
      end

    required ++ any
  end

  defp setup_steps do
    for {{group, label}, number} <- Enum.with_index(setup_groups(), 1),
        do: %{number: number, label: DomainLabels.t(label), detail: step_detail(group)}
  end

  defp step_detail(:tmdb), do: gettext("Add your metadata token.")
  defp step_detail(:indexer), do: gettext("Add your indexers, or connect Prowlarr.")
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
            "Enter and validate your services. Finish unlocks once every checklist row is green or yellow."
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
            indexer_source={@indexer_source}
          >
            <:indexers>
              <.live_component
                module={IndexersComponent}
                id="indexers"
                actor={@current_scope.user}
              />
            </:indexers>
          </.service_fields>
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
            :for={row <- checklist(@statuses)}
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
        {gettext("Finish unlocks once every checklist row is green or yellow.")}
      </p>
    </Layouts.app>
    """
  end

  # One checklist line: a green check when the requirement passes, a yellow warning or a red x
  # with the reason, or a grey hint when it has not been validated yet.
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
        <span
          :if={match?({level, _} when level in [:error, :warning], @status)}
          class={check_color(@status)}
        >
          ({check_reason(elem(@status, 1))})
        </span>
        <span :if={is_nil(@status)} class="text-base-content/70">
          ({@hint || gettext("not checked yet")})
        </span>
      </div>
    </li>
    """
  end

  # The one reason only this page gives; every other comes from the probe.
  defp check_reason(:no_protocol_match),
    do: gettext("No usable indexer uses the same protocol as a working download client.")

  defp check_reason(reason), do: health_reason(reason)

  defp check_icon(:ok), do: "hero-check-circle"
  defp check_icon({:warning, _}), do: "hero-exclamation-triangle"
  defp check_icon({:error, _}), do: "hero-x-circle"
  defp check_icon(_), do: "hero-minus-circle"

  defp check_color(:ok), do: "text-success"
  defp check_color({:warning, _}), do: "text-warning"
  defp check_color({:error, _}), do: "text-error"
  defp check_color(_), do: "text-base-content/40"
end
