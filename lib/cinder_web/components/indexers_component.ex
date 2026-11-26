defmodule CinderWeb.IndexersComponent do
  @moduledoc """
  The configured indexers, as a table in the Indexers group of `/settings` (#1660, #1625 points
  1, 3, 11 and 12). One row per configured indexer, enabled or not, by priority, then id, each
  with its state badge, the state's detail text, its last Test, an enable switch, a Test button
  and Delete. A disabled row shows no detail, save "Credentials can't be decrypted: re-enter
  them" when its secrets do not decrypt. The states, the details and the last Test come from
  `Cinder.Acquisition.IndexerSource.Native.IndexerState.list/1`, the read the dashboard rows use,
  worded by `CinderWeb.IndexerStateText`.

  It renders buttons only, each `type="button"` with no `name`, so the host form's payload never
  holds an indexer field and `FormState` (`assets/js/form_state.js`), which skips buttons,
  restores nothing onto them. The enable control is a `role="switch"` button.

  Its own actions save at once and say so in one `role="status"` line. The switch saves through
  `Cinder.Indexers.set_enabled/4`, checked against the `lock_version` the row was read with, and
  starts no Test. Delete goes through `Cinder.Indexers.delete/2`, which takes no version, and
  sends keyboard focus to the next row's Delete, else the previous row's, else the group's
  title, as the click runs. Test starts one through
  `Cinder.Acquisition.IndexerSource.Native.TestRunner.start/1`. Its button is disabled for an
  indexer whose secrets do not decrypt, and disabled with a spinner while a Test of that indexer
  runs. The status line says when a Test starts and how it ended, a Test that stored no outcome
  and one the runner's restart ended included.

  The rows are read again after a saved switch or Delete, on a Test's finish and on the runner's
  reset, and just past the first running backoff's end, which changes a state with no write to
  tell the page. A Test's start only marks its row, with no read. Each read also
  reads the saved indexer source that Delete's warning names: no field of the page writes it
  until #1662 renders it.
  The rows render through the stream `:table_rows`. Each read sends every row again, since each
  row's Delete warning and focus target read the other rows. A row that keeps its place is
  patched in place, so the focus on its switch or its Delete stays, and only a new order resets
  the stream. The list stays in the `rows` assign for the event handlers.

  The host subscribes to `TestRunner.topic/0` before the component's first render reads
  `TestRunner.running/0`, and forwards each message with
  `send_update(CinderWeb.IndexersComponent, id: id, runner: message)`; a finish reads the rows and
  the running Tests again. Each event's id is client-controlled: one that is no integer, or names
  no row, changes nothing.

  Required assigns: `id` and `actor`, the `%User{}` the audit rows name.
  """
  use CinderWeb, :live_component

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, TestRunner}
  alias Cinder.Indexers
  alias CinderWeb.IndexerStateText

  @impl true
  def mount(socket),
    do: {:ok, stream_configure(socket, :table_rows, dom_id: &"indexer-#{&1.id}")}

  @impl true
  def update(%{runner: message}, socket), do: {:ok, runner_message(socket, message)}

  def update(%{refresh: true}, socket), do: {:ok, load_rows(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :rows),
      do: {:ok, socket},
      else: {:ok, socket |> assign(notice: nil, testing: TestRunner.running()) |> load_rows()}
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

    socket |> assign(testing: TestRunner.running()) |> load_rows()
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
  defp load_rows(socket) do
    stored = Map.new(Indexers.list(), &{&1.id, &1})
    now = Native.now()

    rows =
      for entry <- IndexerState.list(now) do
        row = Map.get(stored, entry.id)

        Map.merge(entry, %{
          lock_version: row && row.lock_version,
          secrets_readable: entry.state != :undecryptable and row != nil and row.secrets_readable
        })
      end

    socket
    |> assign(rows: rows, now: now, only_source?: only_source?())
    |> schedule_refresh(rows, now)
    |> show_rows()
  end

  defp only_source?, do: IndexerSource.configured() == Native

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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

        {:noreply, socket |> assign(notice: notice) |> load_rows()}

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
         socket |> assign(notice: gettext("%{name} deleted.", name: row.name)) |> load_rows()}

      {:error, _reason} ->
        {:noreply, assign(socket, notice: not_saved(row))}
    end
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

  defp testable?(row, testing),
    do: row.secrets_readable and not MapSet.member?(testing, row.id)

  # Whether `entry` passes the gate `IndexerState.passes_gate?/1` applies to the whole list: a
  # usable indexer, or one in a running limit backoff. That module has no per-entry form yet, so
  # `CinderWeb.SettingsIndexersTest` pins this one to it, one enabled indexer per state.
  @doc false
  def passes_gate?(entry),
    do: IndexerState.usable?(entry) or match?({:limit_backoff, _until}, entry.state)

  defp delete_confirm(row, rows, only_source?) do
    question =
      gettext(
        "Delete %{name}? Its grabs still waiting to be sent are dropped: movies and episodes search again, books wait for you.",
        name: row.name
      )

    if only_source? and passes_gate?(row) and
         not Enum.any?(rows, &(&1.id != row.id and passes_gate?(&1))),
       do:
         question <>
           " " <>
           gettext("It is your only working indexer, so searches stop until another one works."),
       else: question
  end

  defp kind(type), do: type |> Atom.to_string() |> String.capitalize()

  defp protocol(:usenet), do: gettext("Usenet")
  defp protocol(:torrent), do: gettext("Torrent")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="mb-4 space-y-2">
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
    </div>
    """
  end
end
