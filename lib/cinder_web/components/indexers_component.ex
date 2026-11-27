defmodule CinderWeb.IndexersComponent do
  @moduledoc """
  The configured indexers, as a table in the Indexers group of `/settings` and of `/setup` (#1660,
  #1663, #1625 points 1, 3, 11 and 12). One row per configured indexer, enabled or not, by priority, then id, each
  with its state badge, the state's detail text, its last Test, an enable switch, a Test button
  and Delete. A disabled row shows no detail, save "Credentials can't be decrypted: re-enter
  them" when its secrets do not decrypt. The states, the details and the last Test come from
  `Cinder.Acquisition.IndexerSource.Native.IndexerState.list/1`, the read the dashboard rows use,
  worded by `CinderWeb.IndexerStateText`.

  Inside the host form it renders buttons only, each `type="button"` with no `name`, so the host
  form's payload never holds an indexer field and `FormState` (`assets/js/form_state.js`), which
  skips buttons, restores nothing onto them. The enable control is a `role="switch"` button.

  "Add indexer" and each row's Edit open a dialog (#1661), rendered with
  `<.portal>` to `body`, so its form is never inside the host form. Add's step 1 searches the
  types by name and description; step 2, and Edit, render the form of `CinderWeb.IndexerDialog`,
  which keeps the typed non-secret values across re-renders and saves through `Cinder.Indexers`.
  The API key input posts under `secrets[api_key]`, which `config :phoenix, :filter_parameters`
  filters from the logs, and its value goes from the save's params to the store, never into an
  assign. A save of an enabled indexer tries to start its Test through `TestRunner.start/1` after
  a create and after an edit that raised `config_version`; while a Test of that indexer still
  runs, the save starts none. A refused save moves focus to the first field it refused. Each
  dialog wraps focus, closes on Escape, and gives focus back to the button that opened it when it
  goes, or to "Add indexer" once the edited indexer's row is gone.

  Cardigann sites (#1676) come from the definitions mirror (`Cinder.Indexers.Definitions`). Add's
  step 1 lists them after Newznab and Torznab, read when the dialog opens: a site whose copy loads
  opens the Cardigann form of `CinderWeb.CardigannDialog`, one that reads not supported, fails or
  is not checked yet is greyed with no click, and with no set loaded the list says so. A
  Cardigann row's Edit opens the same form on the copy it runs. A row whose pin holds an update
  for a credential rule offers Accept update, whose confirm names the held copy's reason and new
  credential hosts and sends the hash it showed. It reads `Definitions.indexer_actions/0`, not
  the row's code, so a disabled row or one whose running copy reads red offers it too, and it
  gives focus back to the row's Edit. Test is disabled for a row whose running copy reads not
  supported or no longer loads. The parts render through `CinderWeb.CardigannComponents`.

  The definitions line under the table shows the set state (`Definitions.set_state/1`), the last
  check and Update now, which calls `Definitions.Updater.update_now/1` and is disabled with a
  spinner while a run is in progress (`Updater.running?/1`). The host subscribes to
  `Updater.topic/0` before the first render and forwards each run's end with
  `send_update(CinderWeb.IndexersComponent, id: id, definitions_update: outcome)`; the line, the
  rows and an open add list read the store again, and the line says how the run ended. Accept
  smaller set reads the refused commit from the store, accepts it and starts a run.

  "Import from Prowlarr" opens the import dialog (#1674) in the same portal, wider: its state is
  a `CinderWeb.ProwlarrImportDialog`, its content `CinderWeb.ProwlarrImportComponents`. Opening
  it and submitting it read Prowlarr in the event handler, `ProwlarrImport.preview/0` and
  `commit/3`, so the page waits for those reads. Each typed API key goes from the submit's params
  to the commit and never into an assign. After a commit, the rows are read again and the host
  gets its notice; the Tests the import started mark their rows as the runner's messages arrive.
  A refused commit moves focus to the alert above the rows, or to the first refused row's name.

  Its own actions save at once and say so in one `role="status"` line. The switch saves through
  `Cinder.Indexers.set_enabled/4`, checked against the `lock_version` the row was read with, and
  starts no Test. Delete goes through `Cinder.Indexers.delete/2`, which takes no version, and
  sends keyboard focus to the next row's Delete, else the previous row's, else the group's
  title, as the click runs. Test starts one through
  `Cinder.Acquisition.IndexerSource.Native.TestRunner.start/1`. Its button is disabled for an
  indexer whose secrets do not decrypt, and disabled with a spinner while a Test of that indexer
  runs. The status line says when a Test starts and how it ended, a Test that stored no outcome
  and one the runner's restart ended included.

  The rows are read again after a saved Add or Edit, a committed import, a saved switch or
  Delete, on a Test's finish and on the runner's reset, on a `%{refresh: true}` update, and just
  past the first running backoff's end, which changes a state with no write to tell the page. A
  Test's start only marks its row, with no read. Each read also reads the saved indexer source
  that Delete's warning names. The Indexers group's "Indexer source" select saves it with the
  host's form, so each host sends the component a `%{refresh: true}` update after each saved
  submit of that form (#1662, #1663).
  The rows render through the stream `:table_rows`. Each read sends every row again, since each
  row's Delete warning and focus target read the other rows. A row that keeps its place is
  patched in place, so the focus on its switch or its Delete stays, and only a new order resets
  the stream. The list stays in the `rows` assign for the event handlers.

  The host subscribes to `TestRunner.topic/0` before the component's first render reads
  `TestRunner.running/0`, and forwards each message with
  `send_update(CinderWeb.IndexersComponent, id: id, runner: message)`; a finish reads the rows and
  the running Tests again, and leaves an open dialog as it is. Each event's payload is
  client-controlled: an id that is no integer or names no row, a type the dialogs do not add,
  and a save whose `indexer` or `secrets` is not a map change nothing. A form value that is not
  text, or under a key the form does not render, is left out of the save.

  After each saved Add or Edit, committed import, saved switch, saved Delete, finished Test and
  `%{refresh: true}` update, the timer's at a backoff's end included, once it has read the rows
  again, the component sends its host's process
  `{CinderWeb.IndexersComponent, :indexers_changed}`: `/setup` recomputes its Finish gate on it,
  and `/settings` ignores it.

  Required assigns: `id` and `actor`, the `%User{}` the audit rows name.
  """
  use CinderWeb, :live_component

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, TestRunner}
  alias Cinder.Indexers
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Hold, Updater}
  alias CinderWeb.{CardigannDialog, DefinitionText, IndexerDialog, IndexerStateText}
  alias CinderWeb.ProwlarrImportDialog

  import CinderWeb.CardigannComponents,
    only: [accept_step: 1, cardigann_form: 1, definition_entries: 1, definitions_line: 1]

  import CinderWeb.ProwlarrImportComponents, only: [import_step: 1]

  # The generic types of the add list; its Cardigann sites come from the definitions mirror.
  @kinds [:newznab, :torznab]

  @impl true
  def mount(socket),
    do: {:ok, stream_configure(socket, :table_rows, dom_id: &"indexer-#{&1.id}")}

  @impl true
  def update(%{runner: message}, socket), do: {:ok, runner_message(socket, message)}

  def update(%{refresh: true}, socket), do: {:ok, socket |> load_rows() |> notify_host()}

  # The end of a definitions update run (`Updater.subscribe/0`, forwarded by the host): the
  # line, the rows' definition codes and an open add list read the store again.
  def update(%{definitions_update: outcome}, socket) do
    {:ok,
     socket
     |> load_definitions(DefinitionText.run_outcome(outcome))
     |> load_rows()
     |> refresh_picker()
     |> notify_host()}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :rows),
      do: {:ok, socket},
      else:
        {:ok,
         socket
         |> assign(notice: nil, dialog: nil, opener: nil, testing: TestRunner.running())
         |> load_definitions(nil)
         |> load_rows()}
  end

  defp runner_message(socket, {TestRunner, :started, id}),
    do: socket |> assign(testing: MapSet.put(socket.assigns.testing, id)) |> show_rows()

  # The runner's own marks, read again: a finish that reaches this page after the next Test of
  # the same indexer started leaves that Test's mark. The notice says how the Test ended, the
  # Tests that store no outcome included; a finish for a row this page no longer lists keeps it.
  defp runner_message(socket, {TestRunner, :finished, id, result}) do
    socket =
      case Enum.find(socket.assigns.rows, &(&1.id == id)) do
        nil -> socket
        row -> assign(socket, notice: test_notice(row, result))
      end

    socket |> assign(testing: TestRunner.running()) |> load_rows() |> notify_host()
  end

  # A restarted runner ended the Tests it held, and an ended Test sends no finish, so the notice
  # says the first of them this page lists did not finish, as a crashed Test's finish would. A
  # row the new runner runs again is no ended one: the page's marks can hold a Test started
  # after the restart, read on a finish the old runner sent before it died.
  defp runner_message(socket, {TestRunner, :reset}) do
    running = TestRunner.running()
    ended = MapSet.difference(socket.assigns.testing, running)

    socket =
      case Enum.find(socket.assigns.rows, &MapSet.member?(ended, &1.id)) do
        nil -> socket
        row -> assign(socket, notice: test_notice(row, {:error, :crashed}))
      end

    socket |> assign(testing: running) |> load_rows()
  end

  defp runner_message(socket, _message), do: socket

  # The lock versions and whether the secrets decrypt come from their own read, just before the
  # states: a write between the two reads leaves a row's version older than its state, and its
  # next save is refused as stale. `:disabled` wins over `:undecryptable` in the state, so the
  # Test button and the detail read `secrets_readable` themselves.
  # A Cardigann row's definition code (`Definitions.indexer_codes/0`) and its held update
  # (`Definitions.indexer_actions/0`) come apart from the state, so a disabled row, whose state
  # is `:disabled`, still offers Accept update.
  defp load_rows(socket) do
    stored = Map.new(Indexers.list(), &{&1.id, &1})
    codes = Definitions.indexer_codes()
    actions = Definitions.indexer_actions()
    now = Native.now()

    rows =
      for entry <- IndexerState.list(now) do
        row = Map.get(stored, entry.id)

        Map.merge(entry, %{
          lock_version: row && row.lock_version,
          secrets_readable: entry.state != :undecryptable and row != nil and row.secrets_readable,
          definition_code: Map.get(codes, entry.id),
          definition_actions: Map.get(actions, entry.id, %{held: nil})
        })
      end

    socket
    |> assign(rows: rows, now: now, only_source?: only_source?())
    |> schedule_refresh(rows, now)
    |> show_rows()
  end

  defp only_source?, do: IndexerSource.configured() == Native

  # The definitions line: the set state, the last check, whether a run is in progress, and the
  # words of the last run's end, kept until the next one.
  defp load_definitions(socket, notice) do
    now = Native.now()

    line = %{
      state: Definitions.set_state(now),
      checked_at: Definitions.last_checked_at(),
      running?: Updater.running?(),
      now: now,
      notice: notice || (socket.assigns[:definitions] && socket.assigns.definitions.notice)
    }

    assign(socket, definitions: line)
  end

  defp picker do
    if Definitions.loaded(), do: Definitions.picker(), else: :not_loaded
  end

  defp refresh_picker(%{assigns: %{dialog: %{step: :pick}}} = socket),
    do: assign(socket, dialog: %{socket.assigns.dialog | picker: picker()})

  defp refresh_picker(socket), do: socket

  # A reset replaces every row's element, and the focus on a switch or a Delete goes with it, so
  # rows that keep their order are patched in place: a gone row is deleted, a kept row is
  # inserted over itself, and a new row goes in at its place. Only a new order resets.
  defp show_rows(socket) do
    %{rows: rows, now: now, testing: testing, only_source?: only_source?} = socket.assigns
    views = Enum.map(rows, &row_view(&1, rows, now, testing, only_source?))
    ids = Enum.map(views, & &1.id)
    shown = socket.assigns[:shown_ids]

    socket =
      if shown != nil and Enum.filter(shown, &(&1 in ids)) == Enum.filter(ids, &(&1 in shown)),
        do: patch_rows(socket, views, shown, ids),
        else: stream(socket, :table_rows, views, reset: true)

    assign(socket, shown_ids: ids)
  end

  defp patch_rows(socket, views, shown, ids) do
    socket =
      Enum.reduce(shown -- ids, socket, &stream_delete(&2, :table_rows, %{id: &1}))

    views
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {view, index}, socket ->
      if view.id in shown,
        do: stream_insert(socket, :table_rows, view),
        else: stream_insert(socket, :table_rows, view, at: index)
    end)
  end

  # Everything a row renders, computed once per row.
  defp row_view(row, rows, now, testing, only_source?) do
    Map.merge(row, %{
      detail: detail_line(row, now),
      last_test_line: row.last_test && IndexerStateText.last_test(row.last_test, now),
      testing?: MapSet.member?(testing, row.id),
      testable?: testable?(row, testing),
      accept?: acceptable?(row.definition_actions),
      confirm: delete_confirm(row, rows, only_source?),
      focus_after_delete: focus_after_delete(row, rows)
    })
  end

  defp detail_line(%{state: :disabled, secrets_readable: false}, now),
    do: IndexerStateText.detail(:undecryptable, now)

  defp detail_line(%{state: :disabled}, _now), do: nil
  defp detail_line(%{state: state}, now), do: IndexerStateText.detail(state, now)

  # A backoff that ends changes its row's state, the badge, the detail and the Delete warning
  # with it, with no write that tells this page. The component reads the rows again just past
  # the first such end, through one timer that each read replaces.
  defp schedule_refresh(socket, rows, now) do
    if timer = socket.assigns[:refresh_timer], do: Process.cancel_timer(timer)

    ends =
      for %{state: state} <- rows,
          until <- [backoff_end(state)],
          until != nil and DateTime.after?(until, now),
          do: until

    timer =
      if ends != [] do
        delay = DateTime.diff(Enum.min(ends, DateTime), now, :millisecond) + 1
        send_update_after(__MODULE__, %{id: socket.assigns.id, refresh: true}, delay)
      end

    assign(socket, refresh_timer: timer)
  end

  defp backoff_end({:limit_backoff, until}), do: until
  defp backoff_end({:failure_backoff, until, _last_failure, _failures}), do: until
  defp backoff_end(_state), do: nil

  @impl true
  def handle_event(event, %{"id" => raw}, socket) when event in ~w(toggle test delete) do
    case find_row(socket, raw) do
      nil -> {:noreply, socket}
      row -> act(event, row, socket)
    end
  end

  def handle_event("open_add", _params, socket),
    do:
      {:noreply,
       assign(socket,
         dialog: %{step: :pick, query: "", picker: picker()},
         opener: "indexers-add"
       )}

  # The file name is client-controlled: only a site of the list read when the dialog opened,
  # whose copy loads, opens a form, on the copy the mirror holds now.
  def handle_event(
        "pick_definition",
        %{"name" => name},
        %{assigns: %{dialog: %{step: :pick}}} = socket
      )
      when is_binary(name) do
    with picker when is_list(picker) <- socket.assigns.dialog.picker,
         %{result: :loads} <- Enum.find(picker, &(&1.name == name)),
         {:in_mirror, %{definition: %{}, result: :loads} = copy} <- Definitions.import_copy(name) do
      {:noreply, assign(socket, dialog: CardigannDialog.add(name, copy))}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("update_definitions", _params, socket) do
    if socket.assigns.definitions.running?,
      do: {:noreply, socket},
      else: {:noreply, start_update(socket, nil)}
  end

  # The commit comes from the stored refusal, never from the page.
  def handle_event("accept_smaller_set", _params, socket) do
    case Definitions.set_state(Native.now()) do
      {kind, %{commit: commit}} when kind in [:shrank, :first_too_small] ->
        :ok = accept_smaller(commit)

        {:noreply,
         start_update(socket, gettext("Smaller set accepted: updating the definitions."))}

      _other ->
        {:noreply, load_definitions(socket, nil)}
    end
  end

  def handle_event("search", %{"query" => query}, %{assigns: %{dialog: %{step: :pick}}} = socket)
      when is_binary(query),
      do: {:noreply, assign(socket, dialog: %{socket.assigns.dialog | query: query})}

  def handle_event("pick", %{"type" => raw}, %{assigns: %{dialog: %{step: :pick}}} = socket) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == raw)) do
      nil -> {:noreply, socket}
      type -> {:noreply, assign(socket, dialog: IndexerDialog.add(type))}
    end
  end

  def handle_event("open_import", _params, socket),
    do: {:noreply, assign(socket, dialog: ProwlarrImportDialog.open(), opener: "indexers-import")}

  def handle_event(
        "import_change",
        params,
        %{assigns: %{dialog: %{step: :import, phase: :preview}}} = socket
      ),
      do:
        {:noreply,
         assign(socket, dialog: ProwlarrImportDialog.change(socket.assigns.dialog, params))}

  def handle_event(
        "import_submit",
        params,
        %{assigns: %{dialog: %{step: :import, phase: :preview}}} = socket
      ),
      do: import_submit(socket, params)

  def handle_event("back", _params, %{assigns: %{dialog: %{mode: :add}}} = socket),
    do: {:noreply, assign(socket, dialog: %{step: :pick, query: "", picker: picker()})}

  def handle_event("close", _params, %{assigns: %{dialog: %{deleted?: true}}} = socket),
    do: {:noreply, socket |> close_dialog("indexers-add") |> load_rows()}

  def handle_event("close", _params, %{assigns: %{dialog: %{}}} = socket),
    do: {:noreply, close_dialog(socket, socket.assigns.opener)}

  def handle_event("open_edit", %{"id" => raw}, socket) do
    case find_row(socket, raw) do
      %{type: :cardigann} = row ->
        {:noreply,
         assign(socket, dialog: CardigannDialog.edit(row.id), opener: "indexer-#{row.id}-edit")}

      %{type: type} = row when type in @kinds ->
        {:noreply,
         assign(socket, dialog: IndexerDialog.edit(row.id), opener: "indexer-#{row.id}-edit")}

      _other ->
        {:noreply, socket}
    end
  end

  # Accept update gives focus back to the row's Edit when it closes: its own button goes once
  # it succeeds.
  def handle_event("open_accept", %{"id" => raw}, socket) do
    with %{} = row <- find_row(socket, raw),
         true <- acceptable?(row.definition_actions) do
      {:noreply,
       assign(socket, dialog: accept_dialog(row, false), opener: "indexer-#{row.id}-edit")}
    else
      _other -> {:noreply, socket}
    end
  end

  # Only while the confirm shows a held copy: a refusal clears it, and a click queued behind that
  # refusal falls to the catch-all.
  def handle_event(
        "accept_update",
        _params,
        %{assigns: %{dialog: %{step: :accept, held: %{blob_sha: _sha}}}} = socket
      ),
      do: accept_update(socket)

  def handle_event(
        "change",
        params,
        %{assigns: %{dialog: %{step: :form, type: :cardigann}}} = socket
      ),
      do:
        {:noreply, assign(socket, dialog: CardigannDialog.change(socket.assigns.dialog, params))}

  def handle_event("change", params, %{assigns: %{dialog: %{step: :form}}} = socket),
    do: {:noreply, assign(socket, dialog: IndexerDialog.change(socket.assigns.dialog, params))}

  # The dialog's form always posts both maps: a save that lacks either changes nothing.
  def handle_event(
        "save",
        %{"indexer" => %{}, "secrets" => %{}} = params,
        %{assigns: %{dialog: %{step: :form, deleted?: false}}} = socket
      ),
      do: save(socket, params)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The dialog goes, and keyboard focus goes back to the button that opened it, or to "Add
  # indexer" when that button's row is gone: `phx:focus-invalid` (`assets/js/app.js`) focuses an
  # element by id once the patch is applied. A `JS.pop_focus/0` from the dialog's `phx-remove`
  # never ran on the element the portal moved to `body` (browser case 13).
  defp close_dialog(socket, opener) do
    opener =
      if opener in ["indexers-add", "indexers-import"] or
           Enum.any?(socket.assigns.rows, &(opener == "indexer-#{&1.id}-edit")),
         do: opener,
         else: "indexers-add"

    socket |> assign(dialog: nil) |> push_event("focus-invalid", %{id: opener})
  end

  # A refused save sends focus to the first field it refused, in the form's order, as a refused
  # save of the settings form does; a refusal shown above the fields moves none.
  defp focus_refusal(socket, dialog) do
    case Enum.find(field_ids(dialog), fn {field, _id} -> dialog.errors[field] end) do
      {_field, id} -> push_event(socket, "focus-invalid", %{id: id})
      nil -> socket
    end
  end

  # The secret input goes from `params` to the store and is never assigned. A save of an enabled
  # indexer tries to start its Test after a create, and after an edit that raised
  # `config_version`: `start_test/1` says when it starts none.
  defp save(socket, params) do
    dialog = socket.assigns.dialog
    form = form_module(dialog)

    case form.save(dialog, socket.assigns.actor, params) do
      {:ok, row} ->
        if row.enabled and form.test_on_save?(dialog, row), do: start_test(row.id)

        notice =
          if dialog.mode == :add,
            do: gettext("%{name} added.", name: row.name),
            else: gettext("%{name} saved.", name: row.name)

        {:noreply,
         socket
         |> assign(notice: notice)
         |> close_dialog(socket.assigns.opener)
         |> load_rows()
         |> notify_host()}

      {:error, dialog} ->
        {:noreply, socket |> assign(dialog: dialog) |> focus_refusal(dialog)}
    end
  end

  # The typed keys go from `params` to the commit and are never assigned. Once the import
  # committed, the rows are read again, the Tests it started mark their rows as the runner's
  # `:started` messages reach the page, and the host gets its notice. A refused commit moves
  # focus to the alert above the rows, else to the first row it refused.
  defp import_submit(socket, params) do
    case ProwlarrImportDialog.submit(socket.assigns.dialog, socket.assigns.actor, params) do
      {:ok, dialog} ->
        {:noreply, socket |> assign(dialog: dialog) |> load_rows() |> notify_host()}

      {:error, dialog} ->
        {:noreply, socket |> assign(dialog: dialog) |> focus_import_refusal(dialog)}
    end
  end

  defp focus_import_refusal(socket, dialog) do
    case ProwlarrImportDialog.focus_id(dialog) do
      nil -> socket
      id -> push_event(socket, "focus-invalid", %{id: id})
    end
  end

  defp form_module(%{type: :cardigann}), do: CardigannDialog
  defp form_module(_dialog), do: IndexerDialog

  defp field_ids(dialog), do: form_module(dialog).field_ids(dialog)

  # `Updater.update_now/1` joins a run already in progress. `{:error, :not_running}`: no worker runs.
  defp start_update(socket, notice) do
    case Updater.update_now() do
      {:ok, _started_or_joined} ->
        socket |> load_definitions(notice) |> assign_running()

      {:error, :not_running} ->
        load_definitions(
          socket,
          gettext("The definitions update isn't running: restart Cinder, then try again.")
        )
    end
  end

  # The run's end can reach the page before `Updater.update_now/1` answers, so the spinner shows only
  # while the worker still runs it.
  defp assign_running(socket),
    do: assign(socket, definitions: %{socket.assigns.definitions | running?: Updater.running?()})

  defp accept_smaller(commit) do
    case Definitions.accept_smaller_set(commit) do
      :ok -> :ok
      {:error, :not_refused} -> :ok
    end
  end

  # The confirm reads the held copy, its reason and its new hosts in one read of the pin, and
  # Confirm sends the hash it showed.
  defp accept_dialog(row, changed?) do
    {held, message} =
      case Definitions.held_update(row.id) do
        {:ok, held} -> {if(held.reason in Hold.credential_reasons(), do: held), nil}
        {:error, reason} -> {nil, accept_refusal(row, reason)}
      end

    %{step: :accept, id: row.id, name: row.name, held: held, changed?: changed?, message: message}
  end

  defp accept_update(socket) do
    %{dialog: dialog, actor: actor} = socket.assigns

    row =
      Enum.find(socket.assigns.rows, &(&1.id == dialog.id)) || %{id: dialog.id, name: dialog.name}

    case Definitions.accept(dialog.id, dialog.held.blob_sha, actor) do
      :ok ->
        {:noreply,
         socket
         |> assign(notice: gettext("%{name}: definition update accepted.", name: dialog.name))
         |> close_dialog(socket.assigns.opener)
         |> load_rows()
         |> notify_host()}

      {:error, :stale} ->
        {:noreply, accept_refused(socket, accept_dialog(row, true))}

      {:error, reason} ->
        {:noreply,
         accept_refused(socket, %{dialog | held: nil, message: accept_refusal(row, reason)})}
    end
  end

  # A confirm with no held copy left drops its Confirm button, which held focus: focus moves to
  # Cancel, inside the dialog.
  defp accept_refused(socket, %{held: nil} = dialog),
    do:
      socket
      |> assign(dialog: dialog)
      |> push_event("focus-invalid", %{id: "indexer-accept-cancel"})

  defp accept_refused(socket, dialog), do: assign(socket, dialog: dialog)

  defp accept_refusal(_row, :stale), do: gettext("No update is held for this indexer now.")
  defp accept_refusal(row, :not_found), do: gettext("%{name} no longer exists.", name: row.name)

  defp accept_refusal(_row, :undecryptable),
    do: IndexerStateText.detail(:undecryptable, nil)

  defp accept_refusal(_row, :fails), do: gettext("The held copy no longer loads.")
  defp accept_refusal(row, _reason), do: not_saved(row)

  defp acceptable?(%{held: reason}), do: reason in Hold.credential_reasons()

  # `{:error, :running}`: a Test of that indexer started before the save still runs, and its
  # answer is dropped for the edit (`Native.test_indexer/1`); the save starts none of its own.
  defp start_test(id), do: _started = TestRunner.start(id)

  defp find_row(socket, raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> Enum.find(socket.assigns.rows, &(&1.id == id))
      _other -> nil
    end
  end

  defp find_row(_socket, _raw), do: nil

  defp act("toggle", row, socket) do
    enabled = not row.enabled

    case Indexers.set_enabled(socket.assigns.actor, row.id, row.lock_version || -1, enabled) do
      {:ok, _row} ->
        notice =
          if enabled,
            do: gettext("%{name} enabled.", name: row.name),
            else: gettext("%{name} disabled.", name: row.name)

        {:noreply, socket |> assign(notice: notice) |> load_rows() |> notify_host()}

      {:error, _reason} ->
        {:noreply, assign(socket, notice: not_saved(row))}
    end
  end

  defp act("test", row, socket) do
    if testable?(row, socket.assigns.testing) do
      # The runner broadcasts the start before it answers, so the page holds the `:started`
      # message, which marks the row, before this handler returns. `{:error, :running}`:
      # another page started it, and this page holds its `:started` already.
      _started = TestRunner.start(row.id)
      {:noreply, assign(socket, notice: gettext("Testing %{name}…", name: row.name))}
    else
      {:noreply, socket}
    end
  end

  defp act("delete", row, socket) do
    case Indexers.delete(socket.assigns.actor, row.id) do
      :ok ->
        {:noreply,
         socket
         |> assign(notice: gettext("%{name} deleted.", name: row.name))
         |> load_rows()
         |> notify_host()}

      {:error, _reason} ->
        {:noreply, assign(socket, notice: not_saved(row))}
    end
  end

  # A LiveComponent runs in its host's process, so the host LiveView's handle_info gets this message
  # once the current event or update returns.
  defp notify_host(socket) do
    send(self(), {__MODULE__, :indexers_changed})
    socket
  end

  defp not_saved(row),
    do: gettext("%{name} could not be saved. Reload the page.", name: row.name)

  # `Native.test_indexer/1`'s answers: the stored outcome, a refusal for a feature Native lacks,
  # a result dropped after an edit, an indexer gone or no longer decryptable, and the rest (a
  # deadline, a crash, a failed write).
  defp test_notice(row, {:ok, %{outcome: outcome}}),
    do:
      gettext("Test of %{name}: %{outcome}.",
        name: row.name,
        outcome: IndexerStateText.test_outcome(outcome)
      )

  defp test_notice(row, {:error, {:not_supported, _feature} = state}),
    do:
      gettext("Test of %{name}: %{outcome}.",
        name: row.name,
        outcome: IndexerStateText.detail(state, nil)
      )

  defp test_notice(row, {:error, :dropped}),
    do:
      gettext("Test of %{name} stored nothing: the indexer changed while it ran.",
        name: row.name
      )

  # Another page deleted it, or its secrets stopped decrypting, after this page read the rows:
  # a new click cannot work, so the notice says why instead of "Try again". The read on the
  # finish drops a deleted row.
  defp test_notice(row, {:error, :not_found}),
    do: gettext("%{name} no longer exists.", name: row.name)

  defp test_notice(row, {:error, :undecryptable_secrets}),
    do:
      gettext("Test of %{name}: %{outcome}.",
        name: row.name,
        outcome: IndexerStateText.detail(:undecryptable, nil)
      )

  defp test_notice(row, _error),
    do: gettext("Test of %{name} did not finish. Try again.", name: row.name)

  # The control a keyboard user lands on once the row is gone: the next row's Delete, else the
  # previous row's, else the group's title.
  defp focus_after_delete(row, rows) do
    index = Enum.find_index(rows, &(&1.id == row.id))
    neighbour = Enum.at(rows, index + 1) || if(index > 0, do: Enum.at(rows, index - 1))

    case neighbour do
      %{id: id} -> "#indexer-#{id}-delete"
      nil -> "#settings-group-indexer > summary"
    end
  end

  # A Cardigann row whose running copy reads not supported or no longer loads has nothing a Test
  # could run (#1625 point 3), as a row whose secrets do not decrypt.
  defp testable?(row, testing),
    do:
      row.secrets_readable and not MapSet.member?(testing, row.id) and
        not red_code?(row.definition_code)

  defp red_code?({:not_supported, _feature}), do: true
  defp red_code?({:no_longer_loads, _reason}), do: true
  defp red_code?(_code), do: false

  defp delete_confirm(row, rows, only_source?) do
    question =
      gettext(
        "Delete %{name}? Its grabs still waiting to be sent are dropped: movies and episodes search again, books wait for you.",
        name: row.name
      )

    if only_source? and IndexerState.passes?(row) and
         not Enum.any?(rows, &(&1.id != row.id and IndexerState.passes?(&1))),
       do:
         question <>
           " " <>
           gettext("It is your only working indexer, so searches stop until another one works."),
       else: question
  end

  defp editable?(type), do: type in [:cardigann | @kinds]

  defp kind(type), do: type |> Atom.to_string() |> String.capitalize()

  # Step 1's list: each type the dialogs add, with what it reaches.
  defp kind_entries do
    [
      %{
        type: :newznab,
        name: "Newznab",
        description: gettext("Any Usenet indexer with an API key")
      },
      %{
        type: :torznab,
        name: "Torznab",
        description: gettext("Any torrent indexer with a Torznab API, or Jackett and Prowlarr")
      }
    ]
  end

  # The entries whose name or description holds the query, case aside.
  defp matching_kinds(query) do
    needle = query |> String.trim() |> String.downcase()

    Enum.filter(kind_entries(), fn entry ->
      String.contains?(String.downcase(entry.name), needle) or
        String.contains?(String.downcase(entry.description), needle)
    end)
  end

  defp close_js(myself), do: JS.push("close", target: myself)

  defp protocol(:usenet), do: gettext("Usenet")
  defp protocol(:torrent), do: gettext("Torrent")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="mb-4 space-y-2">
      <div class="flex flex-wrap justify-end gap-2">
        <.button
          type="button"
          variant="neutral"
          size="sm"
          id="indexers-import"
          phx-click="open_import"
          phx-target={@myself}
          phx-disable-with={gettext("Loading…")}
        >
          {gettext("Import from Prowlarr")}
        </.button>
        <.button
          type="button"
          size="sm"
          id="indexers-add"
          phx-click="open_add"
          phx-target={@myself}
        >
          {gettext("Add indexer")}
        </.button>
      </div>

      <p :if={@rows == []} id="indexers-empty" class="text-sm text-base-content/70">
        {gettext("No indexer added. Add one, or import them from Prowlarr.")}
      </p>

      <div :if={@rows != []} class="w-0 min-w-full overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th scope="col">{gettext("Name")}</th>
              <th scope="col" class="hidden sm:table-cell">{gettext("Kind")}</th>
              <th scope="col">{gettext("State")}</th>
              <th scope="col"><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>
          <tbody id="indexers-rows" phx-update="stream">
            <tr :for={{dom_id, row} <- @streams.table_rows} id={dom_id}>
              <td class="align-top">
                <span class="font-medium">{row.name}</span>
                <span class="block text-xs text-base-content/70 sm:hidden">
                  {kind(row.type)} · {protocol(row.protocol)}
                </span>
              </td>
              <td class="hidden align-top sm:table-cell">
                <span class="block">{kind(row.type)}</span>
                <span class="block text-xs text-base-content/70">{protocol(row.protocol)}</span>
              </td>
              <td class="align-top">
                <.status_badge kind={:indexer} status={row.state} id={"indexer-#{row.id}-badge"} />
                <p :if={row.detail} id={"indexer-#{row.id}-detail"} class="mt-1 text-xs break-words">
                  {row.detail}
                </p>
                <p
                  :if={row.last_test_line}
                  id={"indexer-#{row.id}-last-test"}
                  class="mt-1 text-xs text-base-content/70"
                >
                  {row.last_test_line}
                </p>
                <.button
                  :if={row.accept?}
                  type="button"
                  variant="warning"
                  size="xs"
                  class="mt-1"
                  id={"indexer-#{row.id}-accept"}
                  phx-click="open_accept"
                  phx-value-id={row.id}
                  phx-target={@myself}
                  aria-label={gettext("Accept update for %{name}", name: row.name)}
                >
                  {gettext("Accept update")}
                </.button>
              </td>
              <td class="align-top">
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    role="switch"
                    id={"indexer-#{row.id}-enabled"}
                    aria-checked={to_string(row.enabled)}
                    aria-label={gettext("%{name} enabled", name: row.name)}
                    phx-click="toggle"
                    phx-value-id={row.id}
                    phx-target={@myself}
                    class="group relative inline-flex h-6 w-11 shrink-0 cursor-pointer items-center rounded-full bg-base-300 transition-colors aria-checked:bg-success focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-(--color-focus-ring)"
                  >
                    <span class="inline-block size-5 translate-x-0.5 rounded-full bg-base-100 shadow transition-transform group-aria-checked:translate-x-5" />
                  </button>
                  <.button
                    type="button"
                    variant="neutral"
                    size="sm"
                    id={"indexer-#{row.id}-test"}
                    phx-click="test"
                    phx-value-id={row.id}
                    phx-target={@myself}
                    disabled={not row.testable?}
                    aria-label={gettext("Test %{name}", name: row.name)}
                  >
                    <span
                      :if={row.testing?}
                      class="loading loading-spinner loading-xs"
                      aria-hidden="true"
                    />
                    {gettext("Test")}
                  </.button>
                  <.button
                    :if={editable?(row.type)}
                    type="button"
                    variant="neutral"
                    size="sm"
                    id={"indexer-#{row.id}-edit"}
                    phx-click="open_edit"
                    phx-target={@myself}
                    phx-value-id={row.id}
                    aria-label={gettext("Edit %{name}", name: row.name)}
                  >
                    {gettext("Edit")}
                  </.button>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    class="text-error"
                    id={"indexer-#{row.id}-delete"}
                    phx-click={
                      JS.push("delete", target: @myself)
                      |> JS.focus(to: row.focus_after_delete)
                    }
                    phx-value-id={row.id}
                    data-confirm={row.confirm}
                    aria-label={gettext("Delete %{name}", name: row.name)}
                  >
                    {gettext("Delete")}
                  </.button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p id="indexers-notice" role="status" class="text-sm">{@notice}</p>

      <.definitions_line line={@definitions} myself={@myself} />

      <.portal :if={@dialog} id="indexer-dialog" target="body">
        <div
          id="indexer-dialog-backdrop"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          phx-window-keydown={close_js(@myself)}
          phx-key="Escape"
        >
          <.focus_wrap
            id="indexer-dialog-box"
            role="dialog"
            aria-modal="true"
            aria-labelledby="indexer-dialog-title"
            class={[
              "max-h-full w-full overflow-y-auto rounded-box bg-base-100 p-6 shadow-xl",
              if(@dialog.step == :import, do: "max-w-3xl", else: "max-w-lg")
            ]}
          >
            <.import_step :if={@dialog.step == :import} dialog={@dialog} myself={@myself} />
            <.pick_step :if={@dialog.step == :pick} dialog={@dialog} myself={@myself} />
            <.accept_step :if={@dialog.step == :accept} dialog={@dialog} myself={@myself} />
            <.form_step :if={@dialog.step == :form} dialog={@dialog} myself={@myself} />
          </.focus_wrap>
        </div>
      </.portal>
    </div>
    """
  end

  attr :dialog, :map, required: true
  attr :myself, :any, required: true

  defp pick_step(assigns) do
    %{query: query, picker: picker} = assigns.dialog

    assigns =
      assign(assigns,
        kinds: matching_kinds(query),
        sites:
          if(is_list(picker), do: CinderWeb.CardigannComponents.entries(picker, query), else: []),
        not_loaded?: picker == :not_loaded,
        form: to_form(%{"query" => query})
      )

    ~H"""
    <div id="indexer-dialog-pick" class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">{gettext("Add indexer")}</h2>
      <.form
        for={@form}
        id="indexer-kind-search"
        phx-change="search"
        phx-submit="search"
        phx-target={@myself}
      >
        <.input
          type="search"
          field={@form[:query]}
          id="indexer-kind-query"
          label={gettext("Search indexer types")}
          autocomplete="off"
        />
      </.form>
      <ul id="indexer-kinds" class="space-y-2">
        <li :for={kind <- @kinds}>
          <button
            type="button"
            id={"indexer-kind-#{kind.type}"}
            phx-click="pick"
            phx-value-type={kind.type}
            phx-target={@myself}
            class="w-full rounded-box border border-base-content/20 p-3 text-left hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-(--color-focus-ring)"
          >
            <span class="block font-medium">{kind.name}</span>
            <span class="block text-sm text-base-content/70">{kind.description}</span>
          </button>
        </li>
        <.definition_entries entries={@sites} myself={@myself} />
      </ul>
      <p :if={@not_loaded?} id="indexer-definitions-none" class="text-sm text-base-content/70">
        {gettext("Indexer definitions not loaded yet")}
      </p>
      <p
        :if={@kinds == [] and @sites == []}
        id="indexer-kinds-none"
        class="text-sm text-base-content/70"
      >
        {gettext("No indexer type matches.")}
      </p>
      <div class="flex justify-end">
        <.button type="button" variant="ghost" phx-click={close_js(@myself)}>
          {gettext("Cancel")}
        </.button>
      </div>
    </div>
    """
  end

  attr :dialog, :map, required: true
  attr :myself, :any, required: true

  defp form_step(%{dialog: %{deleted?: true}} = assigns) do
    ~H"""
    <div id="indexer-dialog-deleted" class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">{gettext("Edit indexer")}</h2>
      <p id="indexer-form-deleted" role="alert" class="alert alert-warning text-sm">
        {gettext("This indexer was deleted in another tab.")}
      </p>
      <div class="flex justify-end">
        <.button type="button" phx-click={close_js(@myself)}>{gettext("Close")}</.button>
      </div>
    </div>
    """
  end

  defp form_step(%{dialog: %{type: :cardigann}} = assigns) do
    ~H"""
    <.cardigann_form dialog={@dialog} myself={@myself} />
    """
  end

  defp form_step(assigns) do
    dialog = assigns.dialog

    assigns =
      assign(assigns,
        form: IndexerDialog.to_form(dialog),
        errors: dialog.errors,
        key_saved?: IndexerDialog.key_saved?(dialog),
        through_prowlarr?: IndexerDialog.through_prowlarr?(dialog)
      )

    ~H"""
    <div id={"indexer-dialog-#{@dialog.mode}"} class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">
        {if @dialog.mode == :add, do: gettext("Add indexer"), else: gettext("Edit indexer")}
      </h2>
      <.form
        for={@form}
        id="indexer-form"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
      >
        <p
          :if={@dialog.stale?}
          id="indexer-form-stale"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {gettext("This indexer changed in another tab: reload it before saving.")}
        </p>
        <p
          :if={@dialog.stored_secrets == :unreadable}
          id="indexer-form-unreadable"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {gettext(
            "This indexer's saved secrets can't be decrypted. Type every secret again, or tick its Clear box, before you save a secret."
          )}
        </p>
        <p
          :for={message <- @errors[:form] || []}
          role="alert"
          class="indexer-form-error mb-2 text-sm text-error"
        >
          {message}
        </p>

        <.input
          field={@form[:name]}
          id="indexer-form-name"
          label={gettext("Name")}
          autocomplete="off"
        />
        <p class="mb-2 text-sm">
          <span class="text-base-content/70">{gettext("Kind:")}</span>
          <span id="indexer-form-kind">{kind(@dialog.type)}</span>
        </p>
        <.input
          field={@form[:base_url]}
          id="indexer-form-base-url"
          label={gettext("Base URL")}
          inputmode="url"
          autocomplete="off"
        />
        <.input
          field={@form[:api_path]}
          id="indexer-form-api-path"
          label={gettext("API path")}
          autocomplete="off"
        />
        <p :if={@through_prowlarr?} id="indexer-form-through-prowlarr" class="mb-2 text-sm">
          {gettext(
            "Searched through Prowlarr: Prowlarr drops results that have no size or no categories, and dates undated results now."
          )}
        </p>
        <.input
          type="password"
          id={@dialog.secret_id}
          name="secrets[api_key]"
          value={nil}
          label={gettext("API key")}
          errors={@errors[:api_key] || []}
          placeholder={if @key_saved?, do: gettext("•••• saved (leave blank to keep)"), else: ""}
          autocomplete="off"
          phx-update="ignore"
        />
        <.input
          :if={@key_saved?}
          type="checkbox"
          id="indexer-form-clear-api-key"
          name="secrets[clear_api_key]"
          label={gettext("Clear saved value")}
          checked={@dialog.values["clear_api_key"] == "true"}
        />
        <.input
          :if={@dialog.type == :newznab}
          field={@form[:additional_parameters]}
          id="indexer-form-additional-parameters"
          label={gettext("Additional parameters")}
          autocomplete="off"
        />
        <.input
          type="number"
          field={@form[:priority]}
          id="indexer-form-priority"
          label={gettext("Priority")}
          aria-describedby="indexer-form-priority-help"
        />
        <p id="indexer-form-priority-help" class="-mt-1 mb-2 text-xs text-base-content/70">
          {gettext("1 to 50. A lower number comes first in results.")}
        </p>
        <.input
          type="checkbox"
          field={@form[:enabled]}
          id="indexer-form-enabled"
          label={gettext("Enabled")}
        />

        <p class="mt-2 text-sm text-base-content/70">
          {gettext("Cinder tests an enabled indexer when you save it.")}
        </p>
        <p
          :if={@dialog.mode == :edit}
          id="indexer-form-drops"
          class="mt-1 text-sm text-base-content/70"
        >
          {gettext(
            "A new base URL or any changed credential drops this indexer's grabs still waiting to be sent: movies and episodes search again, books wait for you."
          )}
        </p>

        <div class="mt-4 flex flex-wrap justify-end gap-2">
          <.button
            :if={@dialog.mode == :add}
            type="button"
            variant="ghost"
            id="indexer-form-back"
            phx-click="back"
            phx-target={@myself}
          >
            {gettext("Back")}
          </.button>
          <.button type="button" variant="ghost" phx-click={close_js(@myself)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" id="indexer-form-save">
            {if @dialog.mode == :add, do: gettext("Save and test"), else: gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
