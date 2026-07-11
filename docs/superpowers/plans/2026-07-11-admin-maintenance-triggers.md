# Admin Maintenance Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an authenticated administrator manually run Cinder's four media workers and trigger movie or TV media-server scans from the existing Dashboard.

**Architecture:** Reuse each supervised worker's public `poll/0`, invoked from distinct LiveView `start_async/3` tasks so the page stays responsive and scheduled/manual passes serialize in the existing GenServers. Add only `Cinder.Library.scan/1` for result-returning manual scans; preserve the existing best-effort post-import `refresh/2` contract by routing it through that function.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit, Mox, Gettext, Tailwind/daisyUI.

## Global Constraints

- Keep all six actions on the existing admin-only `/dashboard`; add no route or navigation item.
- Expose only movie pipeline, TV pipeline, monitored-series refresh, subtitle backfill, movie scan, and TV scan.
- Add no scheduler, persistence, run history, global lock, pause control, notification replay, cleanup replay, or dependency.
- Keep automatic post-import scans best-effort and keep worker per-item failure isolation unchanged.
- Keep independent per-action results in the current Dashboard session; do not use shared flash keys.
- Deduplicate an in-flight action only inside one Dashboard session; two sessions may queue two sequential worker passes.
- Preserve the existing admin LiveView authorization boundary at mount; post-demotion session revocation is a separate system-wide concern.
- Every user-facing string must use Gettext and have a complete French translation.
- Follow test-first red-green-refactor and finish with `mix test`.

---

### Task 1: Result-returning manual media-server scan

**Files:**
- Modify: `lib/cinder/library.ex:592-612`
- Modify: `test/cinder/library_test.exs:240-284`

**Interfaces:**
- Consumes: the configured `Cinder.Library.MediaServer.scan/1` behaviour callback.
- Produces: `Cinder.Library.scan(kind)` where `kind :: :movies | :tv`, returning `:ok | {:error, term()}`.
- Preserves: `Cinder.Library.refresh/2` remains best-effort, logs failures, and returns `:ok`.

- [ ] **Step 1: Write the failing `scan/1` tests**

Add immediately before the existing scan-failure import tests in `test/cinder/library_test.exs`:

```elixir
  describe "scan/1" do
    test "returns the configured media server result" do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> {:error, :unavailable} end)

      assert :ok = Library.scan(:movies)
      assert {:error, :unavailable} = Library.scan(:tv)
    end
  end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
mix test test/cinder/library_test.exs
```

Expected: the focused test fails because `Cinder.Library.scan/1` is undefined.

- [ ] **Step 3: Implement the minimum domain entry point**

Replace the current `refresh/2` implementation in `lib/cinder/library.ex` with:

```elixir
  @doc "Requests a library scan and returns the configured media server's result."
  @spec scan(:movies | :tv) :: :ok | {:error, term()}
  def scan(kind), do: media_server().scan(kind)

  @doc false
  @spec refresh(:movies | :tv, String.t()) :: :ok
  def refresh(kind, dest) do
    case scan(kind) do
      {:error, reason} -> log_scan_failure(dest, reason)
      _ -> :ok
    end
  rescue
    e -> log_scan_failure(dest, e)
  catch
    caught, value -> log_scan_failure(dest, {caught, value})
  end
```

Do not move the rescue/catch into `scan/1`: the admin action needs real errors while imports need
the established best-effort boundary.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
mix test test/cinder/library_test.exs
```

Expected: all `Cinder.LibraryTest` tests pass, including the existing returned-error and raised-scan best-effort import cases.

- [ ] **Step 5: Commit Task 1**

```bash
git add lib/cinder/library.ex test/cinder/library_test.exs
git commit -m "feat: expose manual library scans"
```

---

### Task 2: Admin Dashboard maintenance actions

**Files:**
- Modify: `lib/cinder/download/poller_skeleton.ex:37-38`
- Modify: `lib/cinder_web/live/dashboard_live.ex`
- Modify: `test/cinder_web/live/dashboard_live_test.exs`
- Modify: `priv/gettext/default.pot`
- Modify: `priv/gettext/fr/LC_MESSAGES/default.po`

**Interfaces:**
- Consumes: `Cinder.Download.Poller.poll/0`, `Cinder.Download.TvPoller.poll/0`, `Cinder.Catalog.Refresher.poll/0`, `Cinder.Subtitles.Sweeper.poll/0`, and `Cinder.Library.scan/1` from Task 1.
- Produces: Dashboard event `"run_maintenance"` with one of six server-validated action ids; distinct async names `{:maintenance, action_key}`; local running state in `socket.assigns.running_maintenance`.

- [ ] **Step 1: Write failing rendering and worker-dispatch tests**

In `test/cinder_web/live/dashboard_live_test.exs`, import `ExUnit.CaptureLog`, add
`setup :verify_on_exit!` after `setup :set_mox_global`, then add inside
`describe "as an admin"`:

```elixir
    test "shows the six maintenance actions", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      for id <- ~w(movie-pipeline tv-pipeline series-refresh subtitle-backfill scan-movies scan-tv) do
        assert html =~ ~s(id="maintenance-#{id}")
      end
    end

    for {id, worker} <- [
          {"movie-pipeline", Cinder.Download.Poller},
          {"tv-pipeline", Cinder.Download.TvPoller},
          {"series-refresh", Cinder.Catalog.Refresher},
          {"subtitle-backfill", Cinder.Subtitles.Sweeper}
        ] do
      @tag worker: worker
      test "#{id} runs its supervised worker once", %{conn: conn, worker: worker} do
        start_supervised!({worker, interval: 60_000})
        {:ok, lv, _html} = live(conn, ~p"/dashboard")

        lv |> element("#maintenance-#{unquote(id)}") |> render_click()

        render_async(lv)
        assert has_element?(lv, "#maintenance-result-#{unquote(id)}", "Completed")
      end
    end
```

This is mapping-sensitive: each test starts only the expected named worker, so dispatching to a
different worker exits instead of producing the completion result.

- [ ] **Step 2: Write failing scan, running-state, and error tests**

Add in the same admin describe block:

```elixir
    test "movie and TV scan actions pass the intended library kind", %{conn: conn} do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-scan-movies") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")

      lv |> element("#maintenance-scan-tv") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-tv", "Completed")
    end

    test "only the running action is disabled", %{conn: conn} do
      parent = self()

      expect(Cinder.Library.MediaServerMock, :scan, fn :movies ->
        send(parent, {:scan_started, self()})

        receive do
          :finish_scan -> :ok
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#maintenance-scan-movies") |> render_click()
      assert_receive {:scan_started, task}

      assert has_element?(lv, "#maintenance-scan-movies[disabled]")
      refute has_element?(lv, "#maintenance-scan-tv[disabled]")

      send(task, :finish_scan)
      render_async(lv)
      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")
    end

    test "concurrent actions retain independent results", %{conn: conn} do
      stub(Cinder.Library.MediaServerMock, :scan, fn
        :movies -> :ok
        :tv -> {:error, :unavailable}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-scan-movies") |> render_click()
      lv |> element("#maintenance-scan-tv") |> render_click()
      render_async(lv)

      assert has_element?(lv, "#maintenance-result-scan-movies", "Completed")
      assert has_element?(lv, "#maintenance-result-scan-tv", "Failed")
    end

    test "a forged duplicate event does not start an already-running action twice", %{conn: conn} do
      parent = self()

      stub(Cinder.Library.MediaServerMock, :scan, fn :movies ->
        send(parent, {:scan_started, self()})

        receive do
          :finish_scan -> :ok
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#maintenance-scan-movies") |> render_click()
      assert_receive {:scan_started, task}

      render_click(lv, "run_maintenance", %{"action" => "scan-movies"})
      refute_receive {:scan_started, _other_task}, 100

      send(task, :finish_scan)
      render_async(lv)
    end

    test "a returned scan error produces a failure result and logs the reason", %{conn: conn} do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> {:error, :unavailable} end)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      log =
        capture_log(fn ->
          lv |> element("#maintenance-scan-movies") |> render_click()
          render_async(lv)
        end)

      assert has_element?(lv, "#maintenance-result-scan-movies", "Failed")
      refute has_element?(lv, "#maintenance-scan-movies[disabled]")
      assert log =~ "maintenance scan_movies failed: :unavailable"
    end

    test "a missing worker produces a failure result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("#maintenance-movie-pipeline") |> render_click()

      render_async(lv)
      assert has_element?(lv, "#maintenance-result-movie-pipeline", "Failed")
      refute has_element?(lv, "#maintenance-movie-pipeline[disabled]")
    end
```

- [ ] **Step 3: Run the Dashboard tests and verify RED**

Run:

```bash
mix test test/cinder_web/live/dashboard_live_test.exs
```

Expected: maintenance element selectors are missing.

- [ ] **Step 4: Let manual pipeline passes wait for their real result**

In the stateful branch of `Cinder.Download.PollerSkeleton`, match the stateless workers' existing
timeout behavior:

```elixir
          def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)
```

The Dashboard runs this call in a LiveView task, so an external-service-heavy pass cannot freeze
the LiveView. Without this change, the default five-second `GenServer.call` timeout can report a
false failure while the named worker continues and later executes the already-queued call.

- [ ] **Step 5: Add action state, validated dispatch, and result handling**

In `mount/3`, extend the initial assigns:

```elixir
    {:ok,
     socket
     |> assign(
       health: :loading,
       denying: nil,
       maintenance_actions: maintenance_actions(),
       running_maintenance: [],
       maintenance_results: %{}
     )
     |> load()
     |> check_health()}
```

Add these handlers before the catch-all `handle_event/3` and add the `handle_async/3` clauses near
the existing async handlers:

```elixir
  def handle_event("run_maintenance", %{"action" => id}, socket) do
    case Enum.find(socket.assigns.maintenance_actions, &(&1.id == id)) do
      %{key: key} ->
        if key in socket.assigns.running_maintenance do
          {:noreply, socket}
        else
          {:noreply,
           socket
           |> assign(:running_maintenance, [key | socket.assigns.running_maintenance])
           |> assign(:maintenance_results, Map.delete(socket.assigns.maintenance_results, key))
           |> start_async({:maintenance, key}, fn -> run_maintenance(key) end)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async({:maintenance, key}, {:ok, :ok}, socket),
    do: {:noreply, finish_maintenance(socket, key, :ok)}

  def handle_async({:maintenance, key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, maintenance_failed(socket, key, reason)}

  def handle_async({:maintenance, key}, {:exit, reason}, socket),
    do: {:noreply, maintenance_failed(socket, key, reason)}
```

Add the private action definitions and helpers before `render/1`:

```elixir
  defp maintenance_actions do
    [
      %{id: "movie-pipeline", key: :movie_pipeline, label: gettext("Movie pipeline"), description: gettext("Advance movie searches, downloads, imports, and upgrades.")},
      %{id: "tv-pipeline", key: :tv_pipeline, label: gettext("TV pipeline"), description: gettext("Advance monitored TV searches, downloads, and imports.")},
      %{id: "series-refresh", key: :series_refresh, label: gettext("Monitored series refresh"), description: gettext("Reconcile monitored series and episodes with TMDB.")},
      %{id: "subtitle-backfill", key: :subtitle_backfill, label: gettext("Subtitle backfill"), description: gettext("Find missing subtitles for imported movies and episodes.")},
      %{id: "scan-movies", key: :scan_movies, label: gettext("Movie library scan"), description: gettext("Request a movie-library refresh from the media server.")},
      %{id: "scan-tv", key: :scan_tv, label: gettext("TV library scan"), description: gettext("Request a TV-library refresh from the media server.")}
    ]
  end

  defp run_maintenance(:movie_pipeline), do: Cinder.Download.Poller.poll()
  defp run_maintenance(:tv_pipeline), do: Cinder.Download.TvPoller.poll()
  defp run_maintenance(:series_refresh), do: Cinder.Catalog.Refresher.poll()
  defp run_maintenance(:subtitle_backfill), do: Cinder.Subtitles.Sweeper.poll()
  defp run_maintenance(:scan_movies), do: Cinder.Library.scan(:movies)
  defp run_maintenance(:scan_tv), do: Cinder.Library.scan(:tv)

  defp finish_maintenance(socket, key, result) do
    socket
    |> assign(:running_maintenance, List.delete(socket.assigns.running_maintenance, key))
    |> assign(:maintenance_results, Map.put(socket.assigns.maintenance_results, key, result))
  end

  defp maintenance_failed(socket, key, reason) do
    Logger.warning("maintenance #{key} failed: #{inspect(reason)}")
    finish_maintenance(socket, key, :error)
  end
```

Add `require Logger` beside the existing aliases. Format the long list entries with `mix format`;
do not hand-wrap against the formatter.

- [ ] **Step 6: Render the maintenance panel**

Insert this full-width section after the stat strip and before the existing two-column content:

```heex
      <section class="mt-8">
        <div class="mb-3">
          <h2 class="text-lg font-semibold">{gettext("Run maintenance")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("Run a background pass now without changing its schedule.")}
          </p>
        </div>
        <ul class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <li
            :for={action <- @maintenance_actions}
            class="flex items-center justify-between gap-4 rounded-box border border-base-300 bg-base-200/50 p-4"
          >
            <div class="min-w-0">
              <p class="font-medium">{action.label}</p>
              <p class="text-sm text-base-content/70">{action.description}</p>
              <p
                :if={Map.get(@maintenance_results, action.key)}
                id={"maintenance-result-#{action.id}"}
                role="status"
                aria-live="polite"
                class={[
                  "mt-1 text-xs font-medium",
                  Map.get(@maintenance_results, action.key) == :ok && "text-success",
                  Map.get(@maintenance_results, action.key) == :error && "text-error"
                ]}
              >
                {if Map.get(@maintenance_results, action.key) == :ok,
                  do: gettext("Completed"),
                  else: gettext("Failed")}
              </p>
            </div>
            <.button
              id={"maintenance-#{action.id}"}
              variant="neutral"
              size="sm"
              phx-click="run_maintenance"
              phx-value-action={action.id}
              disabled={action.key in @running_maintenance}
              aria-label={gettext("Run %{action}", action: action.label)}
            >
              {if action.key in @running_maintenance, do: gettext("Running…"), else: gettext("Run")}
            </.button>
          </li>
        </ul>
      </section>
```

- [ ] **Step 7: Format, extract messages, and add French translations**

Run:

```bash
mix format lib/cinder/download/poller_skeleton.ex lib/cinder_web/live/dashboard_live.ex test/cinder_web/live/dashboard_live_test.exs
mix gettext.extract --merge
```

Fill the new entries in `priv/gettext/fr/LC_MESSAGES/default.po` with:

```text
Run maintenance = Exécuter la maintenance
Run a background pass now without changing its schedule. = Exécuter une passe en arrière-plan sans modifier sa planification.
Movie pipeline = Pipeline des films
Advance movie searches, downloads, imports, and upgrades. = Faire avancer les recherches, téléchargements, imports et mises à niveau des films.
TV pipeline = Pipeline des séries
Advance monitored TV searches, downloads, and imports. = Faire avancer les recherches, téléchargements et imports des séries suivies.
Monitored series refresh = Actualisation des séries suivies
Reconcile monitored series and episodes with TMDB. = Réconcilier les séries et épisodes suivis avec TMDB.
Subtitle backfill = Complément des sous-titres
Find missing subtitles for imported movies and episodes. = Rechercher les sous-titres manquants des films et épisodes importés.
Movie library scan = Analyse de la médiathèque de films
Request a movie-library refresh from the media server. = Demander au serveur multimédia d’actualiser la médiathèque de films.
TV library scan = Analyse de la médiathèque de séries
Request a TV-library refresh from the media server. = Demander au serveur multimédia d’actualiser la médiathèque de séries.
Running… = Exécution…
Run = Exécuter
Run %{action} = Exécuter : %{action}
Completed = Terminé
Failed = Échec
```

These lines describe the intended `msgid = msgstr` pairs; edit the generated PO entries rather
than pasting this notation into the PO file.

- [ ] **Step 8: Run focused tests and verify GREEN**

Run:

```bash
mix test test/cinder/library_test.exs test/cinder_web/live/dashboard_live_test.exs test/cinder_web/translations_complete_test.exs
```

Expected: all focused tests pass, including gettext currency/completeness.

- [ ] **Step 9: Update the graph and run the source-of-truth gate**

Run:

```bash
graphify update .
mix test
```

Expected: graph update succeeds and the full compile/format/credo/test alias passes.

- [ ] **Step 10: Commit Task 2**

```bash
git add lib/cinder/download/poller_skeleton.ex lib/cinder_web/live/dashboard_live.ex test/cinder_web/live/dashboard_live_test.exs priv/gettext/default.pot priv/gettext/fr/LC_MESSAGES/default.po graphify-out
git commit -m "feat: trigger maintenance from dashboard"
```

If `graphify update .` does not create or modify tracked graph files, omit `graphify-out` from the
`git add` command rather than treating that as a failure.
