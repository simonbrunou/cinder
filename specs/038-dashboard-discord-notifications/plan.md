# Dashboard Discord Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify Discord when a maintenance action launched from the admin Dashboard completes or fails.

**Architecture:** Reuse `Cinder.Notifier` as the only dispatch seam. `DashboardLive` emits typed events from its existing async-result boundary, and the existing Discord and log implementations render them without changing maintenance outcomes.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit, Req.Test, Phoenix.PubSub

## Global Constraints

- Cover all six existing Dashboard maintenance action keys.
- Notify only on completion or failure, never on start, a rejected duplicate, or a scheduled run.
- Include the inspected technical reason in failure notifications.
- Notification delivery remains best-effort and cannot change the Dashboard result.
- Add no dependency, setting, database state, UI, retry mechanism, or notification history.
- Run `mix test` as the source-of-truth compile, format, Credo, and test gate.

## File Structure

- `lib/cinder/notifier/discord.ex`: render maintenance embeds and action names.
- `lib/cinder/notifier/log.ex`: format maintenance events for log-only installations.
- `lib/cinder_web/live/dashboard_live.ex`: emit outcome events.
- Existing notifier and Dashboard test files: cover the new behavior.

---

### Task 1: Render maintenance events

**Files:**
- Modify: `lib/cinder/notifier/discord.ex:20-126`
- Modify: `lib/cinder/notifier/log.ex:8-27`
- Test: `test/cinder/notifier/discord_test.exs`
- Test: `test/cinder/notifier_test.exs`

**Interfaces:**
- Consumes: `Discord.notify(event) :: :ok` and `Log.notify(event) :: :ok`.
- Produces: rendering for `{:maintenance_completed, key}` and `{:maintenance_failed, key, reason}`.

- [ ] **Step 1: Add failing Discord tests**

Add after the existing `movie_upgrade_failed` test:

```elixir
test "maintenance_completed posts a green embed with the operation name" do
  expect_post()
  assert :ok = Discord.notify({:maintenance_completed, :movie_pipeline})

  assert_receive {:posted, %{"embeds" => [embed]}}
  assert embed["title"] == "Maintenance completed"
  assert embed["description"] == "Movie pipeline"
  assert embed["color"] == 0x2ECC71
end

test "maintenance_failed posts a red embed with the technical reason" do
  expect_post()
  assert :ok = Discord.notify({:maintenance_failed, :scan_movies, :unavailable})

  assert_receive {:posted, %{"embeds" => [embed]}}
  assert embed["title"] == "Maintenance failed"
  assert embed["description"] == "Movie library scan — :unavailable"
  assert embed["color"] == 0xE74C3C
end

test "maintenance events safely render an unknown action key" do
  expect_post()
  assert :ok = Discord.notify({:maintenance_completed, :unknown_action})

  assert_receive {:posted, %{"embeds" => [embed]}}
  assert embed["description"] == ":unknown_action"
end
```

- [ ] **Step 2: Add a failing log-format test**

Add after the existing log test in `test/cinder/notifier_test.exs`:

```elixir
test "Log impl formats maintenance outcomes" do
  Logger.configure(level: :info)
  on_exit(fn -> Logger.configure(level: :warning) end)

  log =
    capture_log(fn ->
      assert :ok = Notifier.Log.notify({:maintenance_completed, :scan_tv})
      assert :ok = Notifier.Log.notify({:maintenance_failed, :scan_movies, :unavailable})
    end)

  assert log =~ "maintenance completed: scan_tv"
  assert log =~ "maintenance failed: scan_movies (:unavailable)"
end
```

- [ ] **Step 3: Verify the tests fail**

Run: `mix test test/cinder/notifier/discord_test.exs test/cinder/notifier_test.exs`

Expected: the new Discord tests receive no post, and the log strings do not match.

- [ ] **Step 4: Implement the minimal Discord rendering**

Add below `@image_base`:

```elixir
@maintenance_names %{
  movie_pipeline: "Movie pipeline",
  tv_pipeline: "TV pipeline",
  series_refresh: "Monitored series refresh",
  subtitle_backfill: "Subtitle backfill",
  scan_movies: "Movie library scan",
  scan_tv: "TV library scan"
}
```

Add before the catch-all `embed/1` clause:

```elixir
defp embed({:maintenance_completed, key}),
  do: %{title: "Maintenance completed", description: maintenance_name(key), color: @green}

defp embed({:maintenance_failed, key, reason}),
  do: %{
    title: "Maintenance failed",
    description: "#{maintenance_name(key)} — #{inspect(reason)}",
    color: @red
  }
```

Add before `failure_embed/3`:

```elixir
defp maintenance_name(key), do: Map.get(@maintenance_names, key, inspect(key))
```

- [ ] **Step 5: Implement explicit log rendering**

Add before the catch-all `notify/1` clause:

```elixir
def notify({:maintenance_completed, key}),
  do: log("maintenance completed: #{key}")

def notify({:maintenance_failed, key, reason}),
  do: log("maintenance failed: #{key} (#{inspect(reason)})")
```

- [ ] **Step 6: Format, test, and commit**

```bash
mix format lib/cinder/notifier/discord.ex lib/cinder/notifier/log.ex \
  test/cinder/notifier/discord_test.exs test/cinder/notifier_test.exs
mix test test/cinder/notifier/discord_test.exs test/cinder/notifier_test.exs
git add lib/cinder/notifier/discord.ex lib/cinder/notifier/log.ex \
  test/cinder/notifier/discord_test.exs test/cinder/notifier_test.exs
git commit -m "feat: render dashboard maintenance notifications"
```

Expected: both test files pass and the commit succeeds.

---

### Task 2: Emit Dashboard outcome events

**Files:**
- Modify: `lib/cinder_web/live/dashboard_live.ex:13-75,216-225`
- Test: `test/cinder_web/live/dashboard_live_test.exs:68-172`

**Interfaces:**
- Consumes: `Cinder.Notifier.notify(event) :: :ok` and Task 1's two event shapes.
- Produces: one completion event for `:ok`, or one failure event for an error or async exit.

- [ ] **Step 1: Add the failing success test**

```elixir
test "a completed maintenance action emits one completion notification", %{conn: conn} do
  Cinder.TestNotifier.subscribe()
  expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
  {:ok, lv, _html} = live(conn, ~p"/dashboard")

  lv |> element("#maintenance-scan-movies") |> render_click()
  render_async(lv)

  assert_receive {:notify, {:maintenance_completed, :scan_movies}}
  refute_receive {:notify, _}
end
```

- [ ] **Step 2: Extend the returned-error and task-exit tests**

Subscribe before mounting in both existing tests:

```elixir
Cinder.TestNotifier.subscribe()
```

Add to the returned-error test:

```elixir
assert_receive {:notify, {:maintenance_failed, :scan_movies, :unavailable}}
refute_receive {:notify, _}
```

Add to the missing-worker test:

```elixir
assert_receive {:notify, {:maintenance_failed, :movie_pipeline, _reason}}
refute_receive {:notify, _}
```

- [ ] **Step 3: Prove start and duplicate clicks stay silent**

Replace the existing duplicate-event test with:

```elixir
test "a forged duplicate event does not start or notify twice", %{conn: conn} do
  parent = self()
  Cinder.TestNotifier.subscribe()

  stub(Cinder.Library.MediaServerMock, :scan, fn :movies ->
    send(parent, {:scan_started, self()})

    receive do
      :finish_scan -> :ok
    end
  end)

  {:ok, lv, _html} = live(conn, ~p"/dashboard")
  lv |> element("#maintenance-scan-movies") |> render_click()
  assert_receive {:scan_started, task}
  refute_receive {:notify, _}

  render_click(lv, "run_maintenance", %{"action" => "scan-movies"})
  refute_receive {:scan_started, _other_task}, 100
  refute_receive {:notify, _}

  send(task, :finish_scan)
  render_async(lv)
  assert_receive {:notify, {:maintenance_completed, :scan_movies}}
  refute_receive {:notify, _}
end
```

- [ ] **Step 4: Verify the Dashboard tests fail**

Run: `mix test test/cinder_web/live/dashboard_live_test.exs`

Expected: the new event assertions fail because the LiveView does not dispatch them yet.

- [ ] **Step 5: Emit events from the existing result boundary**

Include `Notifier` in the existing context alias:

```elixir
alias Cinder.{Catalog, Health, Library, Notifier, Requests}
```

Replace the successful maintenance handler:

```elixir
def handle_async({:maintenance, key}, {:ok, :ok}, socket) do
  Notifier.notify({:maintenance_completed, key})
  {:noreply, finish_maintenance(socket, key, :ok)}
end
```

Replace the shared failure helper:

```elixir
defp maintenance_failed(socket, key, reason) do
  Logger.warning("maintenance #{key} failed: #{inspect(reason)}")
  Notifier.notify({:maintenance_failed, key, reason})
  finish_maintenance(socket, key, :error)
end
```

Both existing error/exit handlers continue routing through this helper.

- [ ] **Step 6: Run focused and full verification**

```bash
mix format lib/cinder_web/live/dashboard_live.ex test/cinder_web/live/dashboard_live_test.exs
mix test test/cinder_web/live/dashboard_live_test.exs \
  test/cinder/notifier/discord_test.exs test/cinder/notifier_test.exs
graphify update .
mix test
git diff --check
```

Expected: all commands exit 0 and `git diff --check` prints nothing.

- [ ] **Step 7: Commit and verify repository state**

```bash
git add lib/cinder_web/live/dashboard_live.ex test/cinder_web/live/dashboard_live_test.exs
git add -u graphify-out
git commit -m "feat: notify dashboard maintenance outcomes"
git status --short --branch
git log -3 --oneline
```

Expected: the worktree is clean and the last three commits are event emission, notifier rendering, and this implementation plan.
