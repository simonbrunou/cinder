# M3 — Onboarding wizard + requester UX — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the multi-user movies product installable-and-operable by a stranger: first-run wizard, per-user quota, requester UX (My-requests + per-title badges), a `Cinder.Notifier` seam, and approval-queue polish.

**Architecture:** Build on the seams M2 left. `Cinder.Requests.create_request/2` stays the single approval gate (quota guard added there). `Catalog.transition/2` stays the single state choke-point (the poller's failure parks funnel through one new `park/3` helper). `Cinder.Settings` (generic KV) stores `setup_complete` and `library_path` — only `request_quota` needs a migration. First-run routing is a LiveView `on_mount` hook, not a router plug.

**Tech Stack:** Elixir/Phoenix 1.8 LiveView (HEEx), Ecto + ecto_sqlite3, Mox, daisyUI/Tailwind. Tests via `mix test` (the alias).

## Global Constraints

- `mix test` (the alias) must stay green: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Every new module gets `@moduledoc`; remove now-unused aliases your change creates.
- External services reached only through behaviours; impl resolved at runtime via `Application.fetch_env!/2` (never `compile_env`). Tests never hit the network — Mox mocks only.
- Every movie state change goes through `Catalog.transition/2`. Movie creation from a user action goes only through `Cinder.Requests`.
- New config goes in the `Cinder.Settings` store, not new env vars. Exception: `library_path`'s env bootstrap (`LIBRARY_PATH`) stays as the docker default; the Settings key overlays it.
- Settings-env discipline: any test that calls `Cinder.Settings.put/save/save_form` or mutates `:cinder` Application env must be `async: false` and restore the env + erase the `:persistent_term` base snapshot on exit (see `test/cinder/settings_test.exs`).
- Notifier: default impl is `Cinder.Notifier.Log` in **all** envs (it only logs — harmless in tests). Notification assertions use `ExUnit.CaptureLog`, not a Mox mock (avoids cross-process Mox setup in the poller/LiveView processes).
- First-run redirect (`:require_setup`) is gated by `config :cinder, :enforce_setup` — `true` by default, `false` in `config/test.exs` so the existing LiveView suite (which never marks setup complete) keeps passing. The routing test flips it on locally with `on_exit` restore.

---

### Task 1: `Cinder.Notifier` behaviour + Log default

**Files:**
- Create: `lib/cinder/notifier.ex`
- Create: `lib/cinder/notifier/log.ex`
- Modify: `config/config.exs` (add `:notifier` default)
- Test: `test/cinder/notifier_test.exs`

**Interfaces:**
- Produces: `Cinder.Notifier.notify(event :: term()) :: :ok` — dispatches to the configured impl, never raises. Events used by later tasks: `{:request_approved, request}`, `{:movie_available, movie}`, `{:movie_failed, movie, reason}`.
- Produces: `@callback notify(event :: term()) :: :ok`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/cinder/notifier_test.exs
defmodule Cinder.NotifierTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Notifier

  test "Log impl logs each event and returns :ok" do
    log =
      capture_log(fn ->
        assert :ok = Notifier.Log.notify({:movie_available, %{title: "The Matrix"}})
      end)

    assert log =~ "[notifier]"
    assert log =~ "The Matrix"
  end

  test "notify/1 dispatches to the configured impl" do
    log = capture_log(fn -> assert :ok = Notifier.notify({:movie_failed, %{title: "Dune"}, :boom}) end)
    assert log =~ "Dune"
  end

  test "notify/1 never lets a misbehaving impl crash the caller" do
    original = Application.fetch_env!(:cinder, :notifier)
    Application.put_env(:cinder, :notifier, Cinder.NotifierTest.Raising)
    on_exit(fn -> Application.put_env(:cinder, :notifier, original) end)

    log = capture_log(fn -> assert :ok = Notifier.notify({:movie_available, %{title: "X"}}) end)
    assert log =~ "notifier failed"
  end

  defmodule Raising do
    @behaviour Cinder.Notifier
    @impl true
    def notify(_event), do: raise("nope")
  end
end
```

- [ ] **Step 2: Run it; expect failure** — `mix test test/cinder/notifier_test.exs` → fails (`Cinder.Notifier` undefined).

- [ ] **Step 3: Create the behaviour + dispatcher**

```elixir
# lib/cinder/notifier.ex
defmodule Cinder.Notifier do
  @moduledoc """
  Out-of-band notification seam. `notify/1` dispatches a typed event to the
  configured impl (default `Cinder.Notifier.Log`). A side-effect that must never
  break the pipeline: a raising/exiting impl is caught, logged, and swallowed.

  In-app reactivity (My-requests, per-title badges) rides the existing
  `"requests"`/`"movies"` PubSub topics, so the default impl only logs. This
  behaviour is the seam for real transports (Discord/email) later.
  """
  require Logger

  @callback notify(event :: term()) :: :ok

  @spec notify(term()) :: :ok
  def notify(event) do
    impl().notify(event)
    :ok
  rescue
    e ->
      Logger.warning("notifier failed for #{inspect(event)}: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("notifier #{kind} for #{inspect(event)}: #{inspect(value)}")
      :ok
  end

  defp impl, do: Application.fetch_env!(:cinder, :notifier)
end
```

```elixir
# lib/cinder/notifier/log.ex
defmodule Cinder.Notifier.Log do
  @moduledoc "Default notifier: logs each event. Approvals/failures aren't silent in the logs."
  @behaviour Cinder.Notifier
  require Logger

  @impl true
  def notify({:request_approved, request}),
    do: log("request approved: #{request.title} (user ##{request.user_id})")

  def notify({:movie_available, movie}), do: log("movie available: #{movie.title}")

  def notify({:movie_failed, movie, reason}),
    do: log("movie failed: #{movie.title} (#{inspect(reason)})")

  def notify(other), do: log("event: #{inspect(other)}")

  defp log(msg), do: Logger.info("[notifier] " <> msg)
end
```

- [ ] **Step 4: Wire config default**

In `config/config.exs`, after the `media_server` line (around line 40), add:

```elixir
config :cinder, notifier: Cinder.Notifier.Log
```

- [ ] **Step 5: Run it; expect pass** — `mix test test/cinder/notifier_test.exs` → PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/notifier.ex lib/cinder/notifier/log.ex config/config.exs test/cinder/notifier_test.exs
git commit -m "M3: Cinder.Notifier behaviour + Log default"
```

---

### Task 2: `request_quota` field + Accounts helpers

**Files:**
- Create: `priv/repo/migrations/20260622120000_add_request_quota_to_users.exs`
- Modify: `lib/cinder/accounts/user.ex` (add field + `quota_changeset/2`)
- Modify: `lib/cinder/accounts.ex` (add `admin_exists?/0`, `list_users/0`, `update_user_quota/2`)
- Test: `test/cinder/accounts_test.exs` (add a `describe` block)

**Interfaces:**
- Produces: `User` schema field `request_quota :: integer() | nil`.
- Produces: `Cinder.Accounts.admin_exists?() :: boolean()`, `Cinder.Accounts.list_users() :: [User.t()]`, `Cinder.Accounts.update_user_quota(User.t(), integer() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}`.

- [ ] **Step 1: Write the failing test** (append to `test/cinder/accounts_test.exs`, inside the module)

```elixir
  describe "M3 quota + admin helpers" do
    import Cinder.AccountsFixtures

    test "request_quota defaults to nil and can be set/cleared" do
      user = user_fixture()
      assert user.request_quota == nil
      assert {:ok, user} = Cinder.Accounts.update_user_quota(user, 3)
      assert user.request_quota == 3
      assert {:ok, user} = Cinder.Accounts.update_user_quota(user, nil)
      assert user.request_quota == nil
    end

    test "update_user_quota rejects negatives" do
      user = user_fixture()
      assert {:error, changeset} = Cinder.Accounts.update_user_quota(user, -1)
      assert "must be greater than or equal to 0" in errors_on(changeset).request_quota
    end

    test "admin_exists? reflects whether any user is present" do
      refute Cinder.Accounts.admin_exists?()
      _user = user_fixture()
      assert Cinder.Accounts.admin_exists?()
    end

    test "list_users returns all users ordered by id" do
      a = user_fixture()
      b = user_fixture()
      assert Enum.map(Cinder.Accounts.list_users(), & &1.id) == [a.id, b.id]
    end
  end
```

> Note: `admin_exists?/0` is "any user exists" — the first registered user is always admin (`register_user/1`), so the predicate the wizard needs ("is there an admin to log in as") is `Repo.aggregate(User, :count) > 0`.

- [ ] **Step 2: Run it; expect failure** — `mix test test/cinder/accounts_test.exs` → fails.

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/20260622120000_add_request_quota_to_users.exs
defmodule Cinder.Repo.Migrations.AddRequestQuotaToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :request_quota, :integer
    end
  end
end
```

- [ ] **Step 4: Schema field + changeset** — in `lib/cinder/accounts/user.ex`, add the field after `:role` (line 11):

```elixir
    field :request_quota, :integer
```

And add a changeset (after `confirm_changeset/1`, ~line 129):

```elixir
  @doc "Sets the per-user concurrent-pending request quota (nil = unlimited)."
  def quota_changeset(user, attrs) do
    user
    |> cast(attrs, [:request_quota])
    |> validate_number(:request_quota, greater_than_or_equal_to: 0)
  end
```

- [ ] **Step 5: Accounts helpers** — in `lib/cinder/accounts.ex`, add (after `register_user/1`, ~line 91):

```elixir
  @doc "True if at least one user (hence an admin) exists."
  def admin_exists?, do: Repo.aggregate(User, :count) > 0

  @doc "All users, ordered by id."
  def list_users, do: Repo.all(from u in User, order_by: [asc: u.id])

  @doc "Updates a user's concurrent-pending request quota (nil = unlimited)."
  def update_user_quota(%User{} = user, quota) do
    user |> User.quota_changeset(%{request_quota: quota}) |> Repo.update()
  end
```

- [ ] **Step 6: Run it; expect pass** — `mix test test/cinder/accounts_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260622120000_add_request_quota_to_users.exs lib/cinder/accounts/user.ex lib/cinder/accounts.ex test/cinder/accounts_test.exs
git commit -m "M3: request_quota field + Accounts admin_exists?/list_users/update_user_quota"
```

---

### Task 3: Quota enforcement + notify-on-approved in `Cinder.Requests`

**Files:**
- Modify: `lib/cinder/requests.ex`
- Test: `test/cinder/requests_test.exs` (add cases)

**Interfaces:**
- Consumes: `Cinder.Notifier.notify/1` (Task 1), `User.request_quota` (Task 2).
- Produces: `create_request/2` now returns `{:error, :quota_exceeded}` for a non-admin, non-auto-approve user at/over their concurrent-pending quota. Approval emits `Notifier.notify({:request_approved, request})`.

- [ ] **Step 1: Write the failing tests** (append to `test/cinder/requests_test.exs`)

```elixir
  test "concurrent-pending quota blocks the over-limit request (different targets)" do
    user = user_fixture()
    {:ok, user} = Cinder.Accounts.update_user_quota(user, 1)

    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
    other = Map.put(@attrs, :target_id, 604)
    assert {:error, :quota_exceeded} = Requests.create_request(user, other)
  end

  test "quota does not apply to admins or the auto_approve_all path" do
    admin = admin_fixture()
    {:ok, admin} = Cinder.Accounts.update_user_quota(admin, 0)
    assert {:ok, %{status: :approved}} = Requests.create_request(admin, @attrs)

    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()
    {:ok, user} = Cinder.Accounts.update_user_quota(user, 0)
    assert {:ok, %{status: :approved}} = Requests.create_request(user, Map.put(@attrs, :target_id, 605))
  end

  test "nil quota is unlimited" do
    user = user_fixture()
    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
    assert {:ok, %{status: :pending}} = Requests.create_request(user, Map.put(@attrs, :target_id, 606))
  end

  test "approval emits a notifier event" do
    import ExUnit.CaptureLog
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)

    log = capture_log(fn -> {:ok, _} = Requests.approve_request(req, admin) end)
    assert log =~ "request approved"
    assert log =~ "The Matrix"
  end
```

- [ ] **Step 2: Run; expect failure** — `mix test test/cinder/requests_test.exs` → fails.

- [ ] **Step 3: Add the alias + quota guard.** In `lib/cinder/requests.ex` add `alias Cinder.Notifier` (after the existing aliases, ~line 8). Replace `create_request/2` (lines 25-35) with:

```elixir
  def create_request(%User{} = user, attrs) do
    cond do
      user.role == :admin or Settings.auto_approve_all?() ->
        approver_id = if user.role == :admin, do: user.id, else: nil
        create_approved(user, attrs, approver_id)

      over_quota?(user) ->
        {:error, :quota_exceeded}

      true ->
        %Request{}
        |> Request.create_changeset(Map.merge(attrs, %{user_id: user.id, status: :pending}))
        |> Repo.insert()
        |> tap_ok(&broadcast({:request_created, &1}))
    end
  end

  defp over_quota?(%User{request_quota: nil}), do: false

  defp over_quota?(%User{request_quota: quota, id: id}) do
    pending = Repo.aggregate(from(r in Request, where: r.user_id == ^id and r.status == :pending), :count)
    pending >= quota
  end
```

- [ ] **Step 4: Notify on approval.** Add a private helper and route both approval funnels through it. Replace the two `|> tap_ok(&broadcast({:request_approved, &1}))` lines (in `approve_request/2` line 49 and `create_approved/3` line 81) with `|> tap_ok(&announce_approved/1)`, and add:

```elixir
  defp announce_approved(request) do
    broadcast({:request_approved, request})
    Notifier.notify({:request_approved, request})
  end
```

- [ ] **Step 5: Run; expect pass** — `mix test test/cinder/requests_test.exs` → PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/requests.ex test/cinder/requests_test.exs
git commit -m "M3: concurrent-pending quota gate + notify on approval"
```

---

### Task 4: Notifier call sites in the poller (available + failed via `park/3`)

**Files:**
- Modify: `lib/cinder/download/poller.ex`
- Test: `test/cinder/download/poller_test.exs` (add cases)

**Interfaces:**
- Consumes: `Cinder.Notifier.notify/1`.
- Produces: every terminal failure park routes through `park(movie, status, reason)` (transition + `{:movie_failed, …}`); `:available` emits `{:movie_available, movie}`.

- [ ] **Step 1: Write the failing tests** (append to `test/cinder/download/poller_test.exs`; note the module already has `@moduletag :capture_log`, so use `ExUnit.CaptureLog.with_log/1` to capture+inspect)

```elixir
  test "a movie reaching :available emits the available notifier event" do
    import ExUnit.CaptureLog
    movie = downloaded_movie(40, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})
    stub_successful_import()

    {result, log} = with_log(fn -> Poller.poll() end)
    assert result == :ok
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert log =~ "[notifier] movie available"
  end

  test "a parked movie emits the failed notifier event" do
    import ExUnit.CaptureLog
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 41, title: "M"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloaded})
    start_supervised!({Poller, interval: 60_000})

    {_result, log} = with_log(fn -> Poller.poll() end)
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
    assert log =~ "[notifier] movie failed"
  end
```

- [ ] **Step 2: Run; expect failure** — `mix test test/cinder/download/poller_test.exs` → fails (no notifier log yet).

- [ ] **Step 3: Add the alias + `park/3`.** In `lib/cinder/download/poller.ex` add `alias Cinder.Notifier` (after `alias Cinder.Library`, ~line 26). Add the helper near `retry_or_fail/4` (~line 186):

```elixir
  # A terminal failure park: transition once (the choke-point) then notify. Keeps
  # every "movie gave up" path emitting the same event with no per-site duplication.
  defp park(movie, status, reason) do
    {:ok, parked} = Catalog.transition(movie, %{status: status})
    Notifier.notify({:movie_failed, parked, reason})
    {:ok, parked}
  end
```

- [ ] **Step 4: Route the failure sites through `park/3` and notify on `:available`.** Make these exact replacements in `poller.ex`:

`search_one/1` (lines 98, 102):
```elixir
      {:error, :no_imdb_id} ->
        park(movie, :no_match, :no_imdb_id)

      {:error, reason} when reason in @permanent_search_errors ->
        Logger.warning("movie #{movie.id} search failed permanently: #{inspect(reason)}")
        park(movie, :search_failed, reason)
```

`import_one/1` (lines 171-176):
```elixir
      {:ok, _dest} ->
        {:ok, available} = Catalog.transition(movie, %{status: :available})
        Notifier.notify({:movie_available, available})

      {:error, reason} when reason in @permanent_import_errors ->
        Logger.warning("import permanently failed for movie #{movie.id}: #{inspect(reason)}")
        park(movie, :import_failed, reason)
```

`retry_or_fail/4` exhausted branch (line 194):
```elixir
      park(movie, terminal_status, reason)
```

(Leave the still-retrying `else` branch of `retry_or_fail/4` — the one that re-applies `status: movie.status` — unchanged; it is not a terminal park.)

- [ ] **Step 5: Run; expect pass** — `mix test test/cinder/download/poller_test.exs` → PASS (existing tests still green: `park/3` returns `{:ok, parked}`, the same shape the old inline `Catalog.transition` returned, and callers ignore it).

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/download/poller.ex test/cinder/download/poller_test.exs
git commit -m "M3: notifier events on :available and terminal-failure parks"
```

---

### Task 5: `library_path` in Settings + `Health.check_service(:library)` + settings UI field

**Files:**
- Modify: `lib/cinder/settings.ex`
- Modify: `lib/cinder/health.ex`
- Modify: `lib/cinder_web/live/settings_live.ex`
- Test: `test/cinder/settings_test.exs`, `test/cinder/health_test.exs`

**Interfaces:**
- Produces: `Cinder.Settings.library_path_key/0 :: "library_path"`; `library_path` overlays `:cinder, :library_path` on save (reverts to env bootstrap when cleared); appears in `form_state/0` values and `save_form/1`.
- Produces: `Cinder.Health.check_service(:library) :: :ok | {:error, term()}` — probes the configured `library_path` via the `Filesystem` behaviour's `mkdir_p/1`.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/health_test.exs` (private Mox, `async: true`), add:

```elixir
  test "check_service(:library) is :ok when the library dir is writable" do
    Mox.stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service(:library) == :ok
  end

  test "check_service(:library) surfaces a filesystem error" do
    Mox.stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service(:library) == {:error, :eacces}
  end
```

In `test/cinder/settings_test.exs`, add `"library_path"` to the env-restore discipline and a case (mirror the existing media_server overlay test; ensure the `setup` snapshots `:cinder, :library_path` and erases its persistent_term base):

```elixir
  test "a saved library_path overlays :cinder, :library_path; clearing reverts to bootstrap" do
    original = Application.fetch_env!(:cinder, :library_path)
    Cinder.Settings.put("library_path", "/srv/media/movies")
    assert Application.fetch_env!(:cinder, :library_path) == "/srv/media/movies"

    Cinder.Settings.delete("library_path")
    assert Application.fetch_env!(:cinder, :library_path) == original
  end
```

> In the `settings_test.exs` `setup`, add `:library_path` to the snapshot/restore key list and add `:persistent_term.erase({Cinder.Settings, :base, :library_path})` alongside the existing erases, so the bootstrap snapshot is reset between tests.

- [ ] **Step 2: Run; expect failure** — `mix test test/cinder/settings_test.exs test/cinder/health_test.exs` → fails.

- [ ] **Step 3: Settings — add the special key.** In `lib/cinder/settings.ex`:

Add the module attribute + accessor near `@media_server_key` (line 147):
```elixir
  @library_path_key "library_path"
```
```elixir
  def library_path_key, do: @library_path_key
```

Add `library: "Library"` to `@groups` (line 149-154) so the settings form renders a Library section:
```elixir
  @groups [
    tmdb: "TMDB",
    indexer: "Indexer",
    download: "Download clients",
    media_server: "Media server",
    library: "Library"
  ]
```

In `load_into_env/0` (line 270-275), add `apply_library_path(rows)` to the body:
```elixir
  def load_into_env do
    rows = rows_by_key()
    apply_config_fields(rows)
    apply_media_server(rows)
    apply_download_clients(rows)
    apply_library_path(rows)
    :ok
  rescue
```
And define it next to `apply_media_server/1` (mirrors that pattern exactly):
```elixir
  defp apply_library_path(rows) do
    case decoded_for(rows, @library_path_key) do
      nil -> Application.put_env(:cinder, :library_path, base(:library_path))
      value -> Application.put_env(:cinder, :library_path, value)
    end
  end
```

In `form_state/0` (after the `@media_server_key` put, ~line 217), add the library_path value:
```elixir
      |> Map.put(@library_path_key, decoded_for(rows, @library_path_key) || "")
```

In `plan/1` (line 439-451), thread library_path as a non-secret put/clear before the return:
```elixir
  defp plan(params) do
    config_plan = Enum.reduce(@config_fields, {%{}, []}, &plan_config(&1, params, &2))
    {puts, deletes} = config_plan

    {puts, deletes} =
      if Map.has_key?(params, @library_path_key) do
        case String.trim(params[@library_path_key] || "") do
          "" -> {puts, [@library_path_key | deletes]}
          value -> {Map.put(puts, @library_path_key, value), deletes}
        end
      else
        {puts, deletes}
      end

    puts =
      puts
      |> Map.put(@media_server_key, media_server_choice(params))
      |> then(fn p ->
        Enum.reduce(@toggles, p, fn t, acc -> Map.put(acc, t.key, params[t.key] || "false") end)
      end)

    {puts, deletes}
  end
```

- [ ] **Step 4: Health — add the `:library` clause.** In `lib/cinder/health.ex`, after the `check_service({:download, protocol})` clause (line 34), add:

```elixir
  def check_service(:library) do
    case Application.get_env(:cinder, :library_path) do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      path -> library_writable(path)
    end
  end
```
And a private helper (near `run/1`):
```elixir
  defp library_writable(path) do
    case Application.fetch_env!(:cinder, :filesystem).mkdir_p(path) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end
```

- [ ] **Step 5: Settings LiveView — render the library_path field + Test button.** In `lib/cinder_web/live/settings_live.ex`:
  - In the per-group render, the `:library` group has no `config_fields`, so render its input explicitly. Add a branch in the group rendering: when `group == :library`, render a text input named `library_path` pre-filled from `@form.values["library_path"]` with placeholder `/media/movies`, plus a `phx-click="test" phx-value-service="library"` button and its `test_badge`.
  - In `decode_service/1`, add: `"library" -> :library`.
  - In `services_for/1` (or wherever per-group test buttons are derived), include `:library` for the `:library` group.

  Concretely, follow the existing media_server-select special-case as the template for a group with a non-`@config_fields` control. Keep the markup consistent with the surrounding `setting_field/1` / `test_badge/1` helpers.

- [ ] **Step 6: Run; expect pass** — `mix test test/cinder/settings_test.exs test/cinder/health_test.exs` then `mix test test/cinder_web/live/settings_live_test.exs` (if present) → PASS. Add a small settings_live assertion that the Library section renders an input named `library_path` if a settings_live test file exists; otherwise skip.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/settings.ex lib/cinder/health.ex lib/cinder_web/live/settings_live.ex test/cinder/settings_test.exs test/cinder/health_test.exs
git commit -m "M3: library_path setting + Health.check_service(:library) + settings field"
```

---

### Task 6: First-run wizard — `setup_complete` flag + `SetupLive`

**Files:**
- Modify: `lib/cinder/settings.ex` (add `setup_complete?/0`, `mark_setup_complete/0`)
- Create: `lib/cinder_web/live/setup_live.ex`
- Modify: `lib/cinder_web/router.ex` (add `:setup` live_session + `/setup`)
- Test: `test/cinder_web/live/setup_live_test.exs`

**Interfaces:**
- Consumes: `Cinder.Health.check_service/1`, `Cinder.Settings.save_form/1` + `form_state/0`.
- Produces: `Cinder.Settings.setup_complete?/0 :: boolean()`, `Cinder.Settings.mark_setup_complete/0 :: :ok`. Route `/setup` (admin-gated). `SetupLive` Finish is enabled only when TMDB, indexer, media server, library are `:ok` **and** at least one download client is `:ok`.

- [ ] **Step 1: Write the failing test** (`async: false`, `set_mox_global`; restore `:cinder` settings env on exit per the discipline)

```elixir
# test/cinder_web/live/setup_live_test.exs
defmodule CinderWeb.SetupLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global

  setup do
    # Restore the settings-overlaid env after this test mutates it via save_form.
    keys = [:tmdb, :indexer, :media_server, :download_clients, :library_path]
    saved = Map.new(keys, &{&1, Application.fetch_env!(:cinder, &1)})
    on_exit(fn -> Enum.each(saved, fn {k, v} -> Application.put_env(:cinder, k, v) end) end)
    :ok
  end

  defp stub_all_services_ok do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
  end

  test "an admin validates services and finishes setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()

    {:ok, lv, _html} = live(conn, ~p"/setup")

    lv |> form("#setup-form", %{}) |> render_submit()
    # Finish becomes available once everything is green.
    assert has_element?(lv, "#finish-setup:not([disabled])")

    lv |> element("#finish-setup") |> render_click()
    assert Cinder.Settings.setup_complete?()
  end

  test "a service that fails keeps Finish disabled", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    stub_all_services_ok()
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :econnrefused} end)

    {:ok, lv, _html} = live(conn, ~p"/setup")
    lv |> form("#setup-form", %{}) |> render_submit()
    assert has_element?(lv, "#finish-setup[disabled]")
    refute Cinder.Settings.setup_complete?()
  end

  test "non-admins cannot reach /setup", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
  end
end
```

- [ ] **Step 2: Run; expect failure** — `mix test test/cinder_web/live/setup_live_test.exs` → fails (no route).

- [ ] **Step 3: Settings flag helpers** — in `lib/cinder/settings.ex` (near `auto_approve_all?/0`, line 191):

```elixir
  @doc "True once the first-run wizard has been completed."
  def setup_complete?, do: get("setup_complete") == "true"

  @doc "Marks the first-run wizard complete."
  def mark_setup_complete, do: put("setup_complete", "true")
```

- [ ] **Step 4: `SetupLive`** — create `lib/cinder_web/live/setup_live.ex`:

```elixir
defmodule CinderWeb.SetupLive do
  @moduledoc """
  First-run wizard (admin already created via registration). Collects external-service
  config, validates each via `Cinder.Health`, and only lets the admin finish once the
  movie loop is fully green. Marking `setup_complete` releases the `:require_setup` gate.
  """
  use CinderWeb, :live_view

  alias Cinder.{Health, Settings}

  # Required for a working loop: these must all be :ok, plus at least one download client.
  @required [:tmdb, :indexer, :media_server, :library]
  @download [{:download, :torrent}, {:download, :usenet}]

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
    health = Map.new(@required ++ @download, fn s -> {s, Health.check_service(s)} end)

    {:noreply,
     socket
     |> assign(form: Settings.form_state(), health: health, can_finish: all_green?(health))}
  end

  def handle_event("finish", _params, socket) do
    if socket.assigns.can_finish do
      Settings.mark_setup_complete()
      {:noreply, push_navigate(socket, to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp all_green?(health) do
    Enum.all?(@required, &(health[&1] == :ok)) and Enum.any?(@download, &(health[&1] == :ok))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Set up Cinder
        <:subtitle>Enter and validate your services. Finish unlocks once the movie loop is green.</:subtitle>
      </.header>

      <form id="setup-form" phx-submit="validate" phx-change="validate">
        <.setup_service_fields form={@form} health={@health} />
        <button type="submit" class="btn btn-primary mt-4">Save &amp; validate</button>
      </form>

      <button
        id="finish-setup"
        phx-click="finish"
        disabled={not @can_finish}
        class="btn btn-success mt-6"
      >
        Finish setup
      </button>
    </Layouts.app>
    """
  end

  # ponytail: render the same grouped service inputs the settings page uses. Extract
  # a shared function component if a second copy appears; one copy here is fine.
  defp setup_service_fields(assigns) do
    # Reuse Settings.groups()/config_fields/toggles/media_server/library to render
    # inputs + per-service green/red from @health. Mirror SettingsLive's field markup.
    ~H"""
    <!-- grouped fields here, keyed off Settings.groups() and @health -->
    """
  end
end
```

> Implementation note: `setup_service_fields/1` should render exactly the same field set as `SettingsLive` (TMDB / indexer / download toggles / media-server select / library_path) plus a green/red indicator from `@health[service]`. The cleanest path is to lift `SettingsLive`'s field markup into a shared function component (e.g. `CinderWeb.SettingsComponents`) and call it from both. If that refactor balloons, copy the markup here and leave a `ponytail:` note — the wizard and settings page diverge in chrome anyway.

- [ ] **Step 5: Route** — in `lib/cinder_web/router.ex`, inside the `scope "/", CinderWeb do ... pipe_through :browser` block (after the `:admin` live_session, before line 67's closing), add:

```elixir
    live_session :setup,
      on_mount: [
        {CinderWeb.UserAuth, :require_authenticated},
        {CinderWeb.UserAuth, :require_admin}
      ] do
      live "/setup", SetupLive
    end
```

- [ ] **Step 6: Run; expect pass** — `mix test test/cinder_web/live/setup_live_test.exs` → PASS. Then `mix test` (full) to confirm nothing else broke (require_setup isn't wired yet, so the existing suite is unaffected).

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/settings.ex lib/cinder_web/live/setup_live.ex lib/cinder_web/router.ex test/cinder_web/live/setup_live_test.exs
git commit -m "M3: first-run wizard (SetupLive) + setup_complete flag"
```

---

### Task 7: First-run routing — `:require_setup` on_mount

**Files:**
- Modify: `lib/cinder_web/user_auth.ex` (add `:require_setup` on_mount)
- Modify: `lib/cinder_web/router.ex` (wire it into `:authenticated` + `:admin`)
- Modify: `config/config.exs` (add `:enforce_setup` default true)
- Modify: `config/test.exs` (set `:enforce_setup` false)
- Test: `test/cinder_web/setup_routing_test.exs`

**Interfaces:**
- Consumes: `Cinder.Settings.setup_complete?/0`.
- Produces: `on_mount({CinderWeb.UserAuth, :require_setup}, ...)` — when `:enforce_setup` is on and setup is incomplete, redirects admins to `/setup` and parks non-admins at `/users/log-in`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/cinder_web/setup_routing_test.exs
defmodule CinderWeb.SetupRoutingTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:cinder, :enforce_setup, true)
    on_exit(fn -> Application.put_env(:cinder, :enforce_setup, false) end)
    :ok
  end

  test "incomplete setup redirects an admin to /setup", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/")
  end

  test "completed setup lets the app load normally", %{conn: conn} do
    Cinder.Settings.mark_setup_complete()
    on_exit(fn -> Cinder.Settings.delete("setup_complete") end)
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    assert {:ok, _lv, _html} = live(conn, ~p"/")
  end
end
```

- [ ] **Step 2: Run; expect failure** — `mix test test/cinder_web/setup_routing_test.exs` → fails.

- [ ] **Step 3: Add the on_mount.** In `lib/cinder_web/user_auth.ex`, after the `:require_admin` on_mount (line 261):

```elixir
  def on_mount(:require_setup, _params, _session, socket) do
    cond do
      not enforce_setup?() or Cinder.Settings.setup_complete?() ->
        {:cont, socket}

      admin?(socket.assigns[:current_scope]) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/setup")}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Setup in progress — try again shortly.")
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}
    end
  end

  defp enforce_setup?, do: Application.get_env(:cinder, :enforce_setup, true)
```

- [ ] **Step 4: Wire into the live_sessions.** In `lib/cinder_web/router.ex`, update the `:authenticated` and `:admin` `on_mount` lists:

```elixir
    live_session :authenticated,
      on_mount: [
        {CinderWeb.UserAuth, :require_authenticated},
        {CinderWeb.UserAuth, :require_setup}
      ] do
      live "/", WatchlistLive
    end

    live_session :admin,
      on_mount: [
        {CinderWeb.UserAuth, :require_authenticated},
        {CinderWeb.UserAuth, :require_admin},
        {CinderWeb.UserAuth, :require_setup}
      ] do
      live "/status", StatusLive
      live "/settings", SettingsLive
      live "/requests", RequestsLive
    end
```

- [ ] **Step 5: Config defaults.** In `config/config.exs` add (near the other `:cinder` flags):
```elixir
config :cinder, :enforce_setup, true
```
In `config/test.exs` add (near `start_poller: false`):
```elixir
config :cinder, :enforce_setup, false
```

- [ ] **Step 6: Run; expect pass** — `mix test test/cinder_web/setup_routing_test.exs` → PASS. Then `mix test` (full) — the existing LiveView suite stays green because `:enforce_setup` is false in test.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/user_auth.ex lib/cinder_web/router.ex config/config.exs config/test.exs test/cinder_web/setup_routing_test.exs
git commit -m "M3: first-run routing via :require_setup on_mount (config-gated)"
```

---

### Task 8: `MyRequestsLive` (`/my-requests`) + request-status badge

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `request_status_badge/1`)
- Create: `lib/cinder_web/live/my_requests_live.ex`
- Modify: `lib/cinder_web/router.ex` (add `/my-requests` to `:authenticated`)
- Test: `test/cinder_web/live/my_requests_live_test.exs`

**Interfaces:**
- Consumes: `Cinder.Requests.list_for_user/1` + `subscribe/0`, `Cinder.Catalog.list_watchlist/0` + `subscribe/0`.
- Produces: `CinderWeb.CoreComponents.request_status_badge/1` (attr `:status` ∈ `[:pending, :approved, :denied]`); a per-user requests view.

- [ ] **Step 1: Write the failing test**

```elixir
# test/cinder_web/live/my_requests_live_test.exs
defmodule CinderWeb.MyRequestsLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Cinder.Requests

  test "shows the current user's requests with status, not other users'", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    other = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Requests.create_request(user, %{target_type: "movie", target_id: 1, title: "Mine", year: 2001, poster_path: "/a.jpg"})
    {:ok, _} = Requests.create_request(other, %{target_type: "movie", target_id: 2, title: "Theirs", year: 2002, poster_path: "/b.jpg"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#my-requests", "Mine")
    refute has_element?(lv, "#my-requests", "Theirs")
    assert render(lv) =~ "pending"
  end

  test "live-updates when the user's request is approved", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()
    {:ok, req} = Requests.create_request(user, %{target_type: "movie", target_id: 3, title: "Live", year: 2003, poster_path: "/c.jpg"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    {:ok, _} = Requests.approve_request(req, admin)
    assert render(lv) =~ "approved"
  end
end
```

- [ ] **Step 2: Run; expect failure** — fails (no route/component).

- [ ] **Step 3: Request badge component.** In `lib/cinder_web/components/core_components.ex`, after `movie_status_badge/1` (line 514):

```elixir
  @doc "A daisyUI badge for a request's status (pending/approved/denied)."
  attr :status, :atom, required: true

  def request_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", request_badge_class(@status)]}>{@status}</span>
    """
  end

  defp request_badge_class(:pending), do: "badge-warning"
  defp request_badge_class(:approved), do: "badge-info"
  defp request_badge_class(:denied), do: "badge-error"
```

- [ ] **Step 4: `MyRequestsLive`.**

```elixir
# lib/cinder_web/live/my_requests_live.ex
defmodule CinderWeb.MyRequestsLive do
  @moduledoc "A requester's own requests, with live request + pipeline status. Mounted at /my-requests."
  use CinderWeb, :live_view

  alias Cinder.{Catalog, Requests}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      Catalog.subscribe()
    end

    {:ok, load(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    user = socket.assigns.current_scope.user
    movie_status = Map.new(Catalog.list_watchlist(), &{&1.tmdb_id, &1.status})

    assign(socket, requests: Requests.list_for_user(user), movie_status: movie_status)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>My requests<:subtitle>Track what you've asked for.</:subtitle></.header>

      <p :if={@requests == []} class="text-base-content/60">You haven't requested anything yet.</p>
      <ul id="my-requests" class="space-y-3">
        <li :for={r <- @requests} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{r.title}</span>
            <span :if={r.year} class="text-base-content/60">({r.year})</span>
            <.request_status_badge status={r.status} />
            <.movie_status_badge :if={@movie_status[r.target_id]} status={@movie_status[r.target_id]} />
          </div>
          <p :if={r.status == :denied and r.denial_reason} class="mt-1 text-sm text-error">
            {r.denial_reason}
          </p>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Route** — in `router.ex`, add to the `:authenticated` live_session block:

```elixir
      live "/my-requests", MyRequestsLive
```

- [ ] **Step 6: Run; expect pass** — `mix test test/cinder_web/live/my_requests_live_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live/my_requests_live.ex lib/cinder_web/router.ex test/cinder_web/live/my_requests_live_test.exs
git commit -m "M3: My-requests view + request-status badge"
```

---

### Task 9: Per-title request-state badge on the discovery grid

**Files:**
- Modify: `lib/cinder_web/live/watchlist_live.ex`
- Test: `test/cinder_web/live/watchlist_live_test.exs` (add cases)

**Interfaces:**
- Consumes: `Requests.list_for_user/1`, the composite-state helper below.
- Produces: search results render a per-user composite badge (Pending/Approved/Available/Denied) or an Add button. `add/2` handles `{:error, :quota_exceeded}`.

- [ ] **Step 1: Write the failing tests** (append to `test/cinder_web/live/watchlist_live_test.exs`; reuse the file's existing `stub_search/1` helper)

```elixir
  test "a pending request shows a Pending badge instead of Add", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 27_205, title: "Inception", year: 2010, poster_path: "/i.jpg"})
    conn = log_in_user(conn, user)
    stub_search([@inception])

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#results", "pending")
    refute has_element?(lv, "#add-27205")
  end

  test "a quota-exceeded add shows the quota flash", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, user} = Cinder.Accounts.update_user_quota(user, 0)
    conn = log_in_user(conn, user)
    stub_search([@inception])

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> element("#add-27205") |> render_click()
    assert render(lv) =~ "request limit"
  end
```

> If `@inception` / `stub_search` aren't already defined in the file, define `@inception %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/i.jpg", imdb_id: "tt1375666"}` matching the existing fixtures, and a TMDB search stub.

- [ ] **Step 2: Run; expect failure** — fails.

- [ ] **Step 3: Build the state maps + composite helper.** In `lib/cinder_web/live/watchlist_live.ex`:

In `mount/3`, after assigning the watchlist, add the user's request map and a movie-status map:
```elixir
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false)
     |> assign(watchlist: Catalog.list_watchlist())
     |> assign_request_state()}
  end

  defp assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    request_status = latest_request_status(Cinder.Requests.list_for_user(user))
    movie_status = Map.new(socket.assigns.watchlist, &{&1.tmdb_id, &1.status})
    assign(socket, request_status: request_status, movie_status: movie_status)
  end

  # Latest request per target wins (list_for_user is desc id, so keep the first seen).
  defp latest_request_status(requests) do
    Enum.reduce(requests, %{}, fn r, acc -> Map.put_new(acc, r.target_id, r.status) end)
  end

  # Precedence: an available movie outranks a stale denied/approved request.
  defp title_state(tmdb_id, request_status, movie_status) do
    cond do
      movie_status[tmdb_id] == :available -> :available
      request_status[tmdb_id] == :pending -> :pending
      request_status[tmdb_id] == :approved -> :approved
      request_status[tmdb_id] == :denied -> :denied
      true -> :none
    end
  end
```

Refresh the maps on the existing PubSub handlers — in `handle_info({:movie_updated, …})` and `{:movie_created, …}`, recompute `movie_status` from the updated watchlist (assign `movie_status: Map.new(watchlist, &{&1.tmdb_id, &1.status})` alongside the watchlist assign).

- [ ] **Step 4: Render the composite badge.** Replace the search-results inner block (lines 121-130) so each card shows the badge or the Add button:

```elixir
          <.movie_card :for={m <- @results} movie={m}>
            <% state = title_state(m.tmdb_id, @request_status, @movie_status) %>
            <.composite_badge :if={state != :none} state={state} />
            <button
              :if={state in [:none, :denied]}
              id={"add-#{m.tmdb_id}"}
              phx-click="add"
              phx-value-tmdb_id={m.tmdb_id}
              class="btn btn-primary btn-sm w-full"
            >
              Add
            </button>
          </.movie_card>
```

Add a small badge component (near `movie_card/1`):
```elixir
  attr :state, :atom, required: true

  defp composite_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", composite_class(@state)]}>{@state}</span>
    """
  end

  defp composite_class(:pending), do: "badge-warning"
  defp composite_class(:approved), do: "badge-info"
  defp composite_class(:available), do: "badge-success"
  defp composite_class(:denied), do: "badge-error"
```

> The `<% state = ... %>` inline binding keeps the precedence logic in one place. If credo flags it, hoist `state` by mapping `@results` to `{movie, state}` tuples in an assign instead.

- [ ] **Step 5: Quota flash + refresh on add.** Update `add/2` (lines 81-90) to add the quota branch and refresh `request_status` after a successful create:

```elixir
    case Cinder.Requests.create_request(user, attrs) do
      {:ok, %{status: :approved}} ->
        socket |> put_flash(:info, "#{movie.title} added.") |> assign_request_state()

      {:ok, %{status: :pending}} ->
        socket |> put_flash(:info, "#{movie.title} requested — awaiting approval.") |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(socket, :error, "You've reached your request limit. Wait for approvals to clear.")

      {:error, _} ->
        put_flash(socket, :error, "#{movie.title} is already requested.")
    end
```

- [ ] **Step 6: Run; expect pass** — `mix test test/cinder_web/live/watchlist_live_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/watchlist_live_test.exs
git commit -m "M3: per-title request-state badge on the discovery grid"
```

---

### Task 10: Admin `/users` quota page + approval-queue poster + nav links

**Files:**
- Create: `lib/cinder_web/live/users_live.ex`
- Modify: `lib/cinder_web/router.ex` (add `/users` to `:admin`)
- Modify: `lib/cinder_web/live/requests_live.ex` (render poster)
- Modify: `lib/cinder_web/components/layouts/root.html.heex` (nav links)
- Test: `test/cinder_web/live/users_live_test.exs`, `test/cinder_web/live/requests_live_test.exs` (poster), `test/cinder_web/authorization_test.exs` (gating)

**Interfaces:**
- Consumes: `Accounts.list_users/0`, `Accounts.update_user_quota/2`.
- Produces: admin `/users` route; approval queue shows the poster; nav exposes the new pages.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/cinder_web/live/users_live_test.exs
defmodule CinderWeb.UsersLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "admin sets a user's quota", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> form("#quota-#{user.id}", %{"quota" => "2"}) |> render_submit()

    assert Cinder.Accounts.get_user!(user.id).request_quota == 2
  end
end
```

Add to `test/cinder_web/live/requests_live_test.exs`:
```elixir
  test "the pending queue shows the poster", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 9, title: "P", year: 2009, poster_path: "/poster.jpg"})
    conn = log_in_user(conn, admin)
    {:ok, _lv, html} = live(conn, ~p"/requests")
    assert html =~ "/poster.jpg"
  end
```

Add `/users` to the admin-gated path list in `test/cinder_web/authorization_test.exs` (follow its existing loop-over-paths pattern).

- [ ] **Step 2: Run; expect failure** — fails.

- [ ] **Step 3: `UsersLive`.**

```elixir
# lib/cinder_web/live/users_live.ex
defmodule CinderWeb.UsersLive do
  @moduledoc "Admin user list with per-user request quota. Mounted at /users."
  use CinderWeb, :live_view

  alias Cinder.Accounts

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, users: Accounts.list_users())}

  @impl true
  def handle_event("set_quota", %{"id" => id, "quota" => quota}, socket) do
    user = Accounts.get_user!(String.to_integer(id))

    case Accounts.update_user_quota(user, parse_quota(quota)) do
      {:ok, _} -> {:noreply, assign(socket, users: Accounts.list_users()) |> put_flash(:info, "Quota updated.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Quota must be a non-negative number.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # "" → nil (unlimited); a non-numeric value → :invalid so the changeset rejects it.
  defp parse_quota(""), do: nil

  defp parse_quota(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>Users<:subtitle>Roles and request quotas.</:subtitle></.header>

      <ul class="space-y-3">
        <li :for={u <- @users} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{u.email}</span>
            <span class="badge badge-sm">{u.role}</span>
            <form id={"quota-#{u.id}"} phx-submit="set_quota" class="ml-auto flex items-center gap-2">
              <input type="hidden" name="id" value={u.id} />
              <label class="text-sm">Quota</label>
              <input type="number" name="quota" min="0" value={u.request_quota} class="input input-sm w-24" placeholder="∞" />
              <button class="btn btn-sm">Save</button>
            </form>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Route** — add to the `:admin` live_session in `router.ex`:
```elixir
      live "/users", UsersLive
```

- [ ] **Step 5: Approval-queue poster** — in `lib/cinder_web/live/requests_live.ex`, render the poster inside each pending `<li>` when `r.poster_path` is present:
```elixir
          <img
            :if={r.poster_path}
            src={"https://image.tmdb.org/t/p/w92" <> r.poster_path}
            alt={r.title}
            class="w-12 rounded"
          />
```

- [ ] **Step 6: Nav links** — in `lib/cinder_web/components/layouts/root.html.heex`, inside the `@current_scope` branch (after the email `<li>`, line 36), add:
```heex
        <li><.link navigate={~p"/"}>Search</.link></li>
        <li><.link navigate={~p"/my-requests"}>My requests</.link></li>
        <%= if @current_scope.user.role == :admin do %>
          <li><.link navigate={~p"/requests"}>Requests</.link></li>
          <li><.link navigate={~p"/status"}>Status</.link></li>
          <li><.link navigate={~p"/users"}>Users</.link></li>
          <li><.link navigate={~p"/settings"}>Settings</.link></li>
        <% end %>
```

- [ ] **Step 7: Run; expect pass** — `mix test test/cinder_web/live/users_live_test.exs test/cinder_web/live/requests_live_test.exs test/cinder_web/authorization_test.exs` → PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder_web/live/users_live.ex lib/cinder_web/router.ex lib/cinder_web/live/requests_live.ex lib/cinder_web/components/layouts/root.html.heex test/cinder_web/live/users_live_test.exs test/cinder_web/live/requests_live_test.exs test/cinder_web/authorization_test.exs
git commit -m "M3: admin /users quota page + approval-queue poster + nav"
```

---

### Task 11: M3 done-when integration test (the acceptance gate)

**Files:**
- Create: `test/cinder/m3_pipeline_test.exs`

**Interfaces:**
- Consumes: everything above. This is the roadmap's done-when: non-admin request → admin approval → movie reaches `:available` attributed to the requester, with a notifier event emitted.

- [ ] **Step 1: Write the test**

```elixir
# test/cinder/m3_pipeline_test.exs
defmodule Cinder.M3PipelineTest do
  use Cinder.DataCase, async: false
  import Mox
  import Cinder.AccountsFixtures
  import ExUnit.CaptureLog

  alias Cinder.{Catalog, Requests}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.Poller
  alias Cinder.Repo

  setup :set_mox_global

  @attrs %{target_type: "movie", target_id: 3, title: "Inception", year: 2010, poster_path: "/i.jpg"}

  test "non-admin request → admin approval → :available, attributed, with a notifier event" do
    user = user_fixture()
    admin = admin_fixture()

    # Gate: a non-admin request creates no movie row.
    {:ok, req} = Requests.create_request(user, @attrs)
    assert req.status == :pending
    assert Repo.aggregate(Movie, :count) == 0

    # Need an imdb_id on the movie for the search pass; approval creates it from the request,
    # so set imdb_id via TMDB lookup stub used by the poller's search pass.
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn 3 -> {:ok, %{imdb_id: "tt1375666"}} end)

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [%{title: "Inception.2010.1080p.BluRay.x264-GRP", size: 8_000_000_000, download_url: "magnet:?x", seeders: 10}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _ -> {:ok, "hash-3"} end)
    stub(Cinder.Download.ClientMock, :status, fn "hash-3" -> {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}} end)
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    # Admin approval creates the movie at :requested.
    {:ok, approved} = Requests.approve_request(req, admin)
    assert approved.status == :approved
    assert [%Movie{status: :requested, tmdb_id: 3}] = Catalog.list_by_status(:requested)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    log =
      capture_log(fn ->
        # search runs last in a tick: poll 1 → :downloading, poll 2 → :downloaded → :available
        assert :ok = Poller.poll()
        assert :ok = Poller.poll()
      end)

    assert %Movie{status: :available} = Repo.get_by!(Movie, tmdb_id: 3)
    assert log =~ "[notifier] movie available"

    # Attribution: the request still points at the requester.
    reloaded = Repo.get!(Cinder.Requests.Request, req.id)
    assert reloaded.status == :approved
    assert reloaded.user_id == user.id
  end
end
```

- [ ] **Step 2: Run; expect pass** — `mix test test/cinder/m3_pipeline_test.exs` → PASS. (If the search pass needs the movie's `imdb_id` persisted rather than looked up live, adjust the `get_movie` stub to match how `Download.start/1` resolves the imdb_id — confirm against `poller_test.exs`'s "genuinely-missing imdb" test, which stubs `TMDBMock.get_movie`.)

- [ ] **Step 3: Run the full alias** — `mix test` → green (compile/format/credo/suite).

- [ ] **Step 4: Commit**

```bash
git add test/cinder/m3_pipeline_test.exs
git commit -m "M3: done-when integration test (request → approval → available, attributed)"
```

---

## Self-Review

**Spec coverage:**
- First-run wizard → Tasks 6 (SetupLive + flag) + 7 (routing). Library path in wizard → Task 5 + 6. ✅
- Per-user quota (concurrent-pending) → Task 2 (field) + 3 (enforcement); admin `/users` to set it → Task 10. ✅
- My-requests + per-title badge → Tasks 8 + 9. ✅
- `Cinder.Notifier` (behaviour + Log + call sites approved/available/failed) → Tasks 1 + 3 + 4. ✅
- Approval-queue poster → Task 10. ✅
- Done-when chain (request → approval → available, attributed, notifier event) → Task 11; quota tested → Task 3. ✅

**Deviations from the committed spec (deliberate, noted):**
- No `Cinder.NotifierMock` / `config/test.exs` notifier override. Default `Cinder.Notifier.Log` in all envs; notification assertions use `ExUnit.CaptureLog`. Reason: avoids cross-process Mox setup in the poller/LiveView processes; the Log impl is harmless everywhere.
- First-run redirect gated by `config :cinder, :enforce_setup` (test default off) so the existing LiveView suite, which never marks setup complete, stays green. `signed_in_path/1` and the registration flow are left unchanged — `:require_setup` on the post-login mount is the redirect mechanism.

**Placeholder scan:** `setup_service_fields/1` in Task 6 and the `:library` field rendering in Task 5 are described against the existing `SettingsLive` markup rather than reproduced verbatim (the markup is large and lives in a file the implementer will have open). Every other step has complete code. The `<% state = ... %>` binding in Task 9 has a credo fallback noted.

**Type consistency:** `notify/1` event tuples are identical across Tasks 1/3/4 (`{:request_approved, request}`, `{:movie_available, movie}`, `{:movie_failed, movie, reason}`). `request_quota`, `update_user_quota/2`, `admin_exists?/0`, `list_users/0` names match between Tasks 2 and 3/6/10. `title_state/3` / `composite_badge` names are self-consistent within Task 9. `park/3` returns `{:ok, movie}` matching the transition shape callers ignore.
