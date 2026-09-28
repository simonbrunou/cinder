# Admin CRUD on Entities — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give admins full curated CRUD over Users, Catalog (Movies/Series/Seasons/Episodes), Requests, and Grabs, with safe cancel-vs-delete semantics and an audit trail.

**Architecture:** Hand-rolled Phoenix LiveViews in the existing `:admin` live_session (no admin framework). DB-record-only deletes; in-flight items cancel through the `Catalog.transition` choke-point and remove the orphaned client download via a new `Download.Client.remove/2` callback; every destructive action writes an `admin_audit` row inside the same transaction as the guarded write. On-disk media-file removal is deferred to a future spec.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView (HEEx + daisyUI), Ecto + ecto_sqlite3, ExUnit + Mox, credo --strict.

## Global Constraints

- Gate after every task: `mix test` (compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite) must be green.
- Tests NEVER hit network or disk — external services go through Mox mocks (`Cinder.Download.ClientMock`, `Cinder.Download.SabnzbdClientMock`, `Cinder.Library.FilesystemMock`, `Cinder.Library.MediaServerMock`).
- External-service impls resolve at runtime via `Application.fetch_env!/2` (never `compile_env!`).
- All status writes go through `Catalog.transition/2` (the single state-change choke-point).
- Destructive guards (last-admin, self-delete) live in the context, run inside one `Repo.transaction` with a post-write re-count, and use the server-side `current_scope` actor (never a client `phx-value` id).
- The audit row for a destructive op is written inside that same transaction, after the guard passes.
- `@moduledoc` on every new module; `@impl true` on new behaviour impls; keep the catch-all `handle_event/3`; add a catch-all `handle_info/2` to any newly-subscribed LiveView.
- All work on branch `feat/admin-crud`; commit per task. Spec: `docs/superpowers/specs/2026-06-23-admin-crud-design.md`.
- Reach the code in CT 113: `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && <cmd>'`.

---

## Interface contract (Phase 0 -> consumed by Phases 1-3)

PHASE 0 PRODUCES (consumed verbatim by Phases 1-3):

AUDIT
- `Cinder.Audit.log(actor, action, entity, detail \\ %{}) :: {:ok, %Cinder.Audit.AdminAudit{}} | {:error, %Ecto.Changeset{}}`
  - `actor`: `%Cinder.Accounts.User{}` or `nil` (→ `actor_id` nil). `action`: atom or string (stored as string). `entity`: a persisted struct (→ `entity_type` = last segment of its module name, e.g. `"Movie"`/`"User"`/`"Series"`/`"Grab"`/`"Request"`; `entity_id` = `entity.id`) OR a `{type_string, id}` tuple. `detail`: a map.
  - CRITICAL: `log/4` does NOT open a transaction. Callers MUST call it INSIDE their own `Repo.transaction`, after the guard passes and before commit, so a rolled-back op leaves no orphan audit row.
- Schema `Cinder.Audit.AdminAudit`: fields `actor_id` (belongs_to :actor User, nilify_all), `action` :string, `entity_type` :string, `entity_id` :integer, `detail` :map (default %{}), `inserted_at` only (immutable; no `updated_at`). Table `admin_audit`.

CANCEL/STATUS
- `:cancelled` is now a valid `Cinder.Catalog.Movie` status (Ecto.Enum). Reached only via `Catalog.transition(movie, %{status: :cancelled})` (the choke-point; `transition/2` does NOT validate the transition).
- `@cancellable_movie_statuses` = `[:requested, :searching, :downloading, :downloaded]`.
- `Cinder.Catalog.cancellable?(%Movie{}) :: boolean` — true iff `status in @cancellable_movie_statuses`. Phase 2 `cancel_movie/2` AND `delete_movie/2` share this: an active row with a non-nil `download_id` must be cancelled (client-remove), never bare-deleted.
- `:cancelled` is NOT in `@retryable`/`@parked` (terminal, not re-queueable). `status_badge_class(:cancelled) => "badge-error"` (renders, no crash). NOTE for episodes: no episode status enum exists — TV cancel handled via grab reaping + unmonitor (Phase 2), not a status.

DOWNLOAD CLIENT
- `@callback Cinder.Download.Client.remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}`. Idempotent (unknown id → `:ok`). `opts` carries `delete_files:` (default `true`). Callers SKIP it entirely when the tracked download id is nil.
- Implemented in `Cinder.Download.Client.QBittorrent.remove/2` (POST /api/v2/torrents/delete, form hashes+deleteFiles) and `Cinder.Download.Client.Sabnzbd.remove/2` (mode=queue then history, name=delete value=<id> del_files=1|0).
- Resolve the client per protocol with the EXISTING `Cinder.Download.client_for(protocol) :: {:ok, module} | :error` (nil protocol → :torrent).
- Mox mocks (already defmock'd `for: Cinder.Download.Client` in test/test_helper.exs; remove/2 auto-available): `Cinder.Download.ClientMock` (torrent), `Cinder.Download.SabnzbdClientMock` (usenet). In tests use `expect(Cinder.Download.ClientMock, :remove, fn id, opts -> :ok end)`. Poller/cross-process tests use `setup :set_mox_global`; in-process context tests use `setup :verify_on_exit!`.

BROADCASTS
- `Cinder.Catalog.broadcast_movie_deleted(id) :: :ok` → emits `{:movie_deleted, id}` on the `"movies"` topic (`Catalog.subscribe/0`).
- `Cinder.Catalog.broadcast_series_deleted(id) :: :ok` → emits `{:series_deleted, id}` on the `"series"` topic (`Catalog.subscribe_series/0`).
- Message shapes Phase 2 delete fns fire: `{:movie_deleted, id}` and `{:series_deleted, id}`. (Movie events carry struct on update/create, but DELETE carries only the id, matching the series convention.)
- Subscribers handle them: movies → StatusLive (drops row + now has a catch-all handle_info), WatchlistLive (drops row), MyRequestsLive (reloads via existing catch-all). series → SeriesDetailLive (push_navigate to ~p"/series" if it is the open series), CalendarLive (re-derives rows). All have catch-all handle_info/2.

GUARDS / FK
- `Cinder.Accounts.count_admins/0 :: non_neg_integer` (built in Phase 1 Task 1, used by the Phase 1 guards) — the last-admin guard re-counts AFTER the write/delete inside one `Repo.transaction` (rollback to zero forbidden). Pattern precedent: `Requests.create_pending/2` post-insert re-count (count AFTER, compare with `>`). No separate "guard helper module" is produced — the in-context `Repo.transaction` + post-write `count_admins/0` re-count IS the pattern (Phase 1 implements `update_user_role/2` and `delete_user/1` with it; self-delete guard uses the server-side `current_scope` actor, never a client phx-value id).
- `foreign_keys: :on` is now pinned in config/dev.exs and config/test.exs Repo blocks. Cascades proven by tests and relied on by: `delete_user` (requests.user_id :delete_all; approved_by_id :nilify_all) and `delete_series` (seasons/episodes :delete_all; episodes.grab_id :nilify_all — so Phase 2 `delete_series` MUST reap grabs BEFORE Repo.delete(series), since the episode cascade nilifies grab_id links).

TEST FIXTURES/HELPERS available (do not reinvent): `Cinder.AccountsFixtures` — `user_fixture/0,1`, `admin_fixture/0,1`, `set_password/1`, `unconfirmed_user_fixture/1`, `user_scope_fixture/0,1`. ConnCase setups: `register_and_log_in_admin` (binds `%{conn, user: admin}`), `register_and_log_in_user` (binds `%{conn, user, scope}`). `Cinder.DataCase` imports Repo + `errors_on/1`. No movie/series/grab fixture module exists — build via `Catalog.add_to_watchlist/1` for movies and `Repo.insert!(%Series{}/%Season{}/%Episode{}/%Grab{})` (pattern in catalog_tv_pipeline_test.exs). The single-connection Sandbox means any test exercising a `Repo.transaction` (e.g. transactional guards, create_grab) must be `use Cinder.DataCase, async: false` and/or `setup :set_mox_global`.

---

# Phase 0 — Shared infrastructure (cinder admin-CRUD)

> Branch: `feat/admin-crud`. Gate after every task: `mix test` (runs compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite — wired as the alias; if your repo's `mix test` does not chain these, run `mix format`, `mix credo --strict`, `mix compile --warnings-as-errors`, `mix test` explicitly). All work happens inside CT 113: `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && <cmd>'`. Tests NEVER hit network/disk — external services go through Mox mocks (`Cinder.Download.ClientMock` = torrent, `Cinder.Download.SabnzbdClientMock` = usenet, both `for: Cinder.Download.Client`).
>
> Status writes go through `Catalog.transition/2` (the choke-point). `:cancelled` is a normal transition target. Runtime-resolved impls use `Application.fetch_env!/2` (never `compile_env!`).

---

### Task 1: `Cinder.Download.Client.remove/2` callback (behaviour only)

**Files:**
- Modify: `lib/cinder/download/client.ex` (append a `@callback` after the existing `health/0` callback, ~line 24)

**Interfaces:**
- Consumes: nothing.
- Produces: `@callback remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}` on `Cinder.Download.Client`. Idempotent (unknown id → `:ok`). `opts` carries `delete_files:` (default `true`). Adding this callback makes `Cinder.Download.ClientMock` and `Cinder.Download.SabnzbdClientMock` (already `defmock`'d `for: Cinder.Download.Client` in `test/test_helper.exs`) automatically expose `remove/2` — no test_helper change needed.

- [ ] **Step 1: Write the failing test** — the behaviour is verified through the mock; add a test proving the mock answers `remove/2` (drop into `test/cinder/download_test.exs` or a new `test/cinder/download/client_test.exs`). Create `test/cinder/download/client_test.exs`:
```elixir
defmodule Cinder.Download.ClientTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "the behaviour exposes remove/2 — Mox mocks can expect it" do
    expect(Cinder.Download.ClientMock, :remove, fn "abc", opts ->
      assert Keyword.get(opts, :delete_files, true) == true
      :ok
    end)

    assert :ok = Cinder.Download.ClientMock.remove("abc", [])
  end
end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/download/client_test.exs` — expect `** (ArgumentError) unknown function remove/2 for mock Cinder.Download.ClientMock` (the callback doesn't exist yet, so Mox refuses to `expect` it).
- [ ] **Step 3: Implement** — append to `lib/cinder/download/client.ex` after the `health/0` callback:
```elixir
  @doc """
  Removes a tracked download by `id` (qBittorrent infohash / SABnzbd nzo_id, as
  passed to `status/1`). **Idempotent: an unknown/missing id returns `:ok`** (the
  download may have auto-removed on completion). `opts` carries `delete_files:`
  (default `true` — a cancelled pre-`:available` item's partial download is junk).
  Callers skip this entirely when the tracked download id is nil.
  """
  @callback remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/download/client_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder/download/client.ex test/cinder/download/client_test.exs && git commit -m "feat(download): add Client.remove/2 callback (idempotent download removal)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 2: `QBittorrent.remove/2` impl

**Files:**
- Modify: `lib/cinder/download/client/qbittorrent.ex` (add `@impl true def remove/2` after `health/0`, ~line 105)
- Test: `test/cinder/download/client/qbittorrent_test.exs` (append tests)

**Interfaces:**
- Consumes: `Cinder.Download.Client.remove/2` callback (Task 1); existing private `action/1`, `error/1`, `config/0`.
- Produces: `QBittorrent.remove/2` — `POST /api/v2/torrents/delete` with `form: [hashes: id, deleteFiles: true|false]`. Returns `:ok` on 2xx; `{:error, term}` otherwise.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/download/client/qbittorrent_test.exs` (uses the file's existing `stub_qbit/1` helper that serves the login round-trip then delegates):
```elixir
  test "remove/2 logs in and posts the hash with deleteFiles=true by default" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/delete"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["SID=testsid"]
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["hashes"] == "abc123"
      assert params["deleteFiles"] == "true"
      Req.Test.text(conn, "")
    end)

    assert :ok = QBittorrent.remove("abc123", [])
  end

  test "remove/2 honours delete_files: false" do
    stub_qbit(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["deleteFiles"] == "false"
      Req.Test.text(conn, "")
    end)

    assert :ok = QBittorrent.remove("abc123", delete_files: false)
  end

  test "remove/2 surfaces a login failure" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn -> Req.Test.text(conn, "Fails.") end)
    assert {:error, :login_failed} = QBittorrent.remove("abc123", [])
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/download/client/qbittorrent_test.exs` — expect `(UndefinedFunctionError) function Cinder.Download.Client.QBittorrent.remove/2 is undefined`.
- [ ] **Step 3: Implement** — insert into `lib/cinder/download/client/qbittorrent.ex` after the `health/0` clause (before the private `action/1`):
```elixir
  @impl true
  def remove(hash, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, true)

    case action(fn req ->
           Req.post(req,
             url: "/api/v2/torrents/delete",
             form: [hashes: hash, deleteFiles: to_string(delete_files)]
           )
         end) do
      # qBittorrent answers /torrents/delete with 200 and an empty body whether or
      # not the hash was known — so it is idempotent for free (unknown hash → :ok).
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/download/client/qbittorrent_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder/download/client/qbittorrent.ex test/cinder/download/client/qbittorrent_test.exs && git commit -m "feat(qbittorrent): implement Client.remove/2 (POST /torrents/delete)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 3: `Sabnzbd.remove/2` impl

**Files:**
- Modify: `lib/cinder/download/client/sabnzbd.ex` (add `@impl true def remove/2` after `health/0`, ~line 120)
- Test: `test/cinder/download/client/sabnzbd_test.exs` (append tests)

**Interfaces:**
- Consumes: `Cinder.Download.Client.remove/2` callback (Task 1); existing private `get/1`, `error/1`, `config/0`.
- Produces: `Sabnzbd.remove/2` — deletes from queue (`mode=queue&name=delete&value=<id>&del_files=1|0`), and if not found there, from history (`mode=history&name=delete&value=<id>&del_files=1|0`). Returns `:ok` (idempotent — unknown id is `:ok`); `{:error, term}` on transport/status error.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/download/client/sabnzbd_test.exs` (uses the file's existing `stub/1` helper):
```elixir
  test "remove/2 deletes from the queue with del_files=1 by default" do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["mode"] == "queue"
      assert conn.params["name"] == "delete"
      assert conn.params["value"] == "nzo-1"
      assert conn.params["del_files"] == "1"
      assert conn.params["apikey"] == "test-key"
      Req.Test.json(conn, %{"status" => true})
    end)

    assert :ok = Sabnzbd.remove("nzo-1", [])
  end

  test "remove/2 falls through to history when the queue delete reports no match" do
    stub(fn conn ->
      case conn.params["mode"] do
        "queue" -> Req.Test.json(conn, %{"status" => false})
        "history" ->
          assert conn.params["name"] == "delete"
          assert conn.params["value"] == "nzo-1"
          Req.Test.json(conn, %{"status" => true})
      end
    end)

    assert :ok = Sabnzbd.remove("nzo-1", [])
  end

  test "remove/2 honours delete_files: false (del_files=0)" do
    stub(fn conn ->
      assert conn.params["del_files"] == "0"
      Req.Test.json(conn, %{"status" => true})
    end)

    assert :ok = Sabnzbd.remove("nzo-1", delete_files: false)
  end

  test "remove/2 is idempotent: an unknown id (false in both lists) still returns :ok" do
    stub(fn conn -> Req.Test.json(conn, %{"status" => false}) end)
    assert :ok = Sabnzbd.remove("ghost", [])
  end

  test "remove/2 returns an error tuple on a non-2xx status" do
    stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom") end)
    assert {:error, {:sabnzbd_status, 500}} = Sabnzbd.remove("nzo-1", [])
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/download/client/sabnzbd_test.exs` — expect `(UndefinedFunctionError) function Cinder.Download.Client.Sabnzbd.remove/2 is undefined`.
- [ ] **Step 3: Implement** — insert into `lib/cinder/download/client/sabnzbd.ex` after the `health/0` clause (before private `get/1`):
```elixir
  @impl true
  def remove(nzo_id, opts \\ []) do
    del = if Keyword.get(opts, :delete_files, true), do: "1", else: "0"

    # A queued job is deleted via mode=queue; a finished/post-processing job lives
    # in history and needs mode=history. SABnzbd reports a no-match delete as
    # status=false (not an error), so a false from the queue delete falls through
    # to a history delete; a false from *both* means the id is gone already —
    # which is success for an idempotent remove (unknown id -> :ok).
    case delete_in("queue", nzo_id, del) do
      :ok -> :ok
      :not_deleted -> delete_in_history(nzo_id, del)
      {:error, _} = err -> err
    end
  end

  defp delete_in_history(nzo_id, del) do
    case delete_in("history", nzo_id, del) do
      :ok -> :ok
      :not_deleted -> :ok
      {:error, _} = err -> err
    end
  end

  defp delete_in(mode, nzo_id, del) do
    case get(mode: mode, name: "delete", value: nzo_id, del_files: del) do
      {:ok, %{status: 200, body: %{"status" => false}}} -> :not_deleted
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/download/client/sabnzbd_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder/download/client/sabnzbd.ex test/cinder/download/client/sabnzbd_test.exs && git commit -m "feat(sabnzbd): implement Client.remove/2 (queue+history delete, idempotent)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 4: `:cancelled` status on `Movie` + `status_badge_class(:cancelled)`

**Files:**
- Modify: `lib/cinder/catalog/movie.ex` (`@statuses` list, lines 13–22)
- Modify: `lib/cinder_web/components/core_components.ex` (add a clause after line 536; the existing clauses are 529–536 and there is **NO catch-all**, so a missing clause raises `FunctionClauseError` at render)
- Test: `test/cinder/catalog_test.exs` (append a transition test); `test/cinder_web/live/status_live_test.exs` (append a badge-render test)

**Interfaces:**
- Consumes: `Catalog.transition/2`; `Catalog.add_to_watchlist/1`.
- Produces: `:cancelled` is now a valid `Movie.@statuses` Ecto.Enum value (Phase 2's `cancel_movie/2` transitions into it). `status_badge_class(:cancelled)` → `"badge-error"` (renders without crashing on `/status`, `/`, `/my-requests`).

- [ ] **Step 1: Write the failing test** — append to `test/cinder/catalog_test.exs` inside the `describe "transition/2, ..."` block:
```elixir
    test "transition/2 accepts :cancelled as a valid status" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 4242, title: "M"})

      assert {:ok, %Movie{status: :cancelled}} =
               Catalog.transition(movie, %{status: :cancelled})
    end
```
And append to `test/cinder_web/live/status_live_test.exs` (proves the badge renders — catches the `status_badge_class` crash):
```elixir
  test "renders a :cancelled movie's status badge without crashing", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9300, title: "Cancelled Pic"})
    {:ok, _} = Catalog.transition(movie, %{status: :cancelled})

    {:ok, _lv, html} = live(conn, ~p"/status")
    assert html =~ "Cancelled Pic"
    assert html =~ "badge-error"
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_test.exs` (the transition fails: `%{status: ["is invalid"]}`) and `mix test test/cinder_web/live/status_live_test.exs` (raises `FunctionClauseError` for `status_badge_class/1` at render).
- [ ] **Step 3: Implement** — in `lib/cinder/catalog/movie.ex` add `:cancelled` to `@statuses`:
```elixir
  @statuses [
    :requested,
    :searching,
    :downloading,
    :downloaded,
    :available,
    :no_match,
    :search_failed,
    :import_failed,
    :cancelled
  ]
```
In `lib/cinder_web/components/core_components.ex` add the clause after the `:import_failed` line (537):
```elixir
  defp status_badge_class(:cancelled), do: "badge-error"
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_test.exs test/cinder_web/live/status_live_test.exs`. Also re-run the full suite once (`mix test`) — the `@parked`/composite-status sites (`status_live.ex @parked`, `watchlist_live.ex` status display) need no change: `:cancelled` is intentionally NOT parked (not retryable) and renders via the new badge clause. Note for Phase 2: `@parked`/`@retryable` deliberately exclude `:cancelled` (a cancelled movie is terminal, not re-queueable).
- [ ] **Step 5: Commit** — `git add lib/cinder/catalog/movie.ex lib/cinder_web/components/core_components.ex test/cinder/catalog_test.exs test/cinder_web/live/status_live_test.exs && git commit -m "feat(catalog): add :cancelled movie status + badge clause (no render crash)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 5: `@cancellable_movie_statuses` predicate in `Catalog`

**Files:**
- Modify: `lib/cinder/catalog.ex` (add the module attribute + a public predicate near `@retryable`, ~line 91)
- Test: `test/cinder/catalog_test.exs` (append)

**Interfaces:**
- Consumes: `Movie` struct.
- Produces: `Catalog.cancellable?(%Movie{})` :: `boolean`, true iff `status in [:requested, :searching, :downloading, :downloaded]`. Phase 2's `cancel_movie/2` and `delete_movie/2` share this predicate (delete must route an active row with a non-nil `download_id` through cancel so it can't orphan the client download). NOTE: `transition/2` validates nothing, so this guard is the explicit gate.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/catalog_test.exs`:
```elixir
  describe "cancellable?/1" do
    test "is true for active statuses and false for terminal/parked ones" do
      for s <- [:requested, :searching, :downloading, :downloaded] do
        assert Catalog.cancellable?(%Movie{status: s}), "expected #{s} cancellable"
      end

      for s <- [:available, :no_match, :search_failed, :import_failed, :cancelled] do
        refute Catalog.cancellable?(%Movie{status: s}), "expected #{s} NOT cancellable"
      end
    end
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_test.exs` — expect `(UndefinedFunctionError) function Cinder.Catalog.cancellable?/1 is undefined`.
- [ ] **Step 3: Implement** — in `lib/cinder/catalog.ex`, directly after the `@retryable` attribute + `retry_movie/1` clauses (~line 112), add:
```elixir
  # The active set a movie can be cancelled out of (mirrors @retryable's shape).
  # transition/2 does NOT validate transitions, so cancel/delete must guard on this
  # explicitly. delete_movie/2 (Phase 2) shares it: an active row with a download_id
  # must be cancelled (which removes the client download), never bare-deleted.
  @cancellable_movie_statuses [:requested, :searching, :downloading, :downloaded]

  @doc "True if `movie` is in an active status that can be cancelled (`#{inspect(@cancellable_movie_statuses)}`)."
  def cancellable?(%Movie{status: status}), do: status in @cancellable_movie_statuses
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder/catalog.ex test/cinder/catalog_test.exs && git commit -m "feat(catalog): add @cancellable_movie_statuses predicate (cancellable?/1)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 6: `admin_audit` migration

**Files:**
- Create: `priv/repo/migrations/20260623130000_create_admin_audit.exs` (timestamp must sort after the latest existing migration `20260623120000_*`)

**Interfaces:**
- Consumes: nothing (FK to existing `users` table).
- Produces: the `admin_audit` table: `id`, `actor_id` (FK `users`, `on_delete: :nilify_all`), `action` (string), `entity_type` (string), `entity_id` (integer), `detail` (`:map` → SQLite JSON TEXT), `inserted_at` only (immutable audit rows — no `updated_at`).

- [ ] **Step 1: Write the failing test** — this is a schema-less DDL task; the failing test is the schema test in Task 7 (which selects from `admin_audit`). Skip a standalone test here. (To confirm the migration is valid in isolation: `mix ecto.migrate` against the dev DB is a manual sanity check, but the suite uses `MIX_ENV=test` which migrates the test DB automatically on `mix test`.)
- [ ] **Step 2: Run it, expect FAIL** — covered by Task 7 Step 2.
- [ ] **Step 3: Implement** — create `priv/repo/migrations/20260623130000_create_admin_audit.exs`:
```elixir
defmodule Cinder.Repo.Migrations.CreateAdminAudit do
  use Ecto.Migration

  # Records every destructive admin action (who/what/when). `detail` is an Ecto :map
  # stored as JSON TEXT by ecto_sqlite3. Append-only: rows are immutable (inserted_at
  # only, no updated_at). actor_id nilifies on user delete so the trail outlives the actor.
  def change do
    create table(:admin_audit) do
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :integer
      add :detail, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:admin_audit, [:actor_id])
    create index(:admin_audit, [:entity_type, :entity_id])
  end
end
```
- [ ] **Step 4: Run, expect PASS** — covered by Task 7 Step 4 (`mix test` re-migrates the test DB).
- [ ] **Step 5: Commit** — committed together with Task 7 (the migration is meaningless without the context). See Task 7 Step 5.

---

### Task 7: `Cinder.Audit` context + `AdminAudit` schema

**Files:**
- Create: `lib/cinder/audit.ex`
- Create: `lib/cinder/audit/admin_audit.ex`
- Test: `test/cinder/audit_test.exs`

**Interfaces:**
- Consumes: the `admin_audit` table (Task 6); `Cinder.Accounts.User`; `Cinder.Repo`.
- Produces:
  - `Cinder.Audit.AdminAudit` schema (`belongs_to :actor, User`; `action`, `entity_type`, `entity_id`, `detail` map; `inserted_at`).
  - `Cinder.Audit.log(actor, action, entity, detail)` :: `{:ok, %AdminAudit{}}` | `{:error, changeset}`. `actor` is `%User{}` (or nil → `actor_id: nil`); `action` is an atom or string; `entity` is any persisted struct (its `__struct__` last segment → `entity_type`, its `id` → `entity_id`) **or** a `{type_string, id}` tuple; `detail` is a map. **It uses `Repo.insert` with no transaction of its own — callers call it INSIDE their own `Repo.transaction` (after the guard, before commit) so a rolled-back op leaves no orphan audit row.** Phases 1–3 call `Audit.log/4` in-txn for every destructive action.

- [ ] **Step 1: Write the failing test** — create `test/cinder/audit_test.exs`:
```elixir
defmodule Cinder.AuditTest do
  use Cinder.DataCase, async: true

  import Cinder.AccountsFixtures

  alias Cinder.Audit
  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog

  describe "log/4" do
    test "writes an audit row from an actor, action, entity struct, and detail map" do
      admin = admin_fixture()
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 1, title: "M"})

      assert {:ok, %AdminAudit{} = row} =
               Audit.log(admin, :delete_movie, movie, %{title: "M"})

      assert row.actor_id == admin.id
      assert row.action == "delete_movie"
      assert row.entity_type == "Movie"
      assert row.entity_id == movie.id
      assert row.detail == %{title: "M"}
      assert %DateTime{} = row.inserted_at
    end

    test "accepts a {type, id} tuple entity" do
      admin = admin_fixture()
      assert {:ok, row} = Audit.log(admin, :delete_user, {"User", 99}, %{email: "x@y.z"})
      assert row.entity_type == "User"
      assert row.entity_id == 99
    end

    test "accepts a nil actor (system action) without crashing" do
      assert {:ok, row} = Audit.log(nil, :purge, {"Grab", 5}, %{})
      assert row.actor_id == nil
    end

    test "rolls back with the caller's transaction (no orphan audit row)" do
      admin = admin_fixture()

      result =
        Repo.transaction(fn ->
          {:ok, _} = Audit.log(admin, :delete_movie, {"Movie", 1}, %{})
          Repo.rollback(:boom)
        end)

      assert result == {:error, :boom}
      assert Repo.aggregate(AdminAudit, :count) == 0
    end
  end
end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/audit_test.exs` — expect `(CompileError) ... Cinder.Audit ... undefined` / `module Cinder.Audit.AdminAudit is not loaded`.
- [ ] **Step 3: Implement** —
  Create `lib/cinder/audit/admin_audit.ex`:
```elixir
defmodule Cinder.Audit.AdminAudit do
  @moduledoc """
  An append-only record of one destructive admin action (who/what/when). `detail`
  is a free-form map (stored as JSON TEXT by ecto_sqlite3). Rows are immutable —
  `inserted_at` only, no `updated_at`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Accounts.User

  schema "admin_audit" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :integer
    field :detail, :map, default: %{}
    belongs_to :actor, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [:actor_id, :action, :entity_type, :entity_id, :detail])
    |> validate_required([:action, :entity_type])
  end
end
```
  Create `lib/cinder/audit.ex`:
```elixir
defmodule Cinder.Audit do
  @moduledoc """
  Admin audit trail. `log/4` records one destructive admin action.

  **The write happens inside the caller's `Repo.transaction`** — call it after the
  guard passes and before commit, so a rolled-back op (e.g. a last-admin delete)
  leaves no orphan audit row. `log/4` itself opens no transaction.
  """
  alias Cinder.Accounts.User
  alias Cinder.Audit.AdminAudit
  alias Cinder.Repo

  @doc """
  Records `action` (atom or string) taken by `actor` (`%User{}` or nil) against
  `entity` (a persisted struct, or a `{type_string, id}` tuple), with a free-form
  `detail` map. Returns `{:ok, %AdminAudit{}}` or `{:error, changeset}`.
  """
  def log(actor, action, entity, detail \\ %{}) do
    {entity_type, entity_id} = entity_ref(entity)

    %AdminAudit{}
    |> AdminAudit.changeset(%{
      actor_id: actor_id(actor),
      action: to_string(action),
      entity_type: entity_type,
      entity_id: entity_id,
      detail: detail
    })
    |> Repo.insert()
  end

  defp actor_id(%User{id: id}), do: id
  defp actor_id(nil), do: nil

  defp entity_ref({type, id}) when is_binary(type), do: {type, id}

  defp entity_ref(%mod{id: id}) do
    {mod |> Module.split() |> List.last(), id}
  end
end
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/audit_test.exs` (this also exercises the Task 6 migration — `mix test` re-migrates the test DB).
- [ ] **Step 5: Commit** (migration + context + schema together) — `git add priv/repo/migrations/20260623130000_create_admin_audit.exs lib/cinder/audit.ex lib/cinder/audit/admin_audit.ex test/cinder/audit_test.exs && git commit -m "feat(audit): admin_audit table + Cinder.Audit.log/4 (in-caller-txn)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 8: Delete broadcast helpers in `Catalog` + `StatusLive` handles them (+ its missing catch-all)

**Files:**
- Modify: `lib/cinder/catalog.ex` (add two public broadcast helpers: one near the movie `broadcast/1` ~line 147, one near `broadcast_series/1` ~line 843)
- Modify: `lib/cinder_web/live/status_live.ex` (add `handle_info({:movie_deleted, id}, ...)` after line 35 + a catch-all `handle_info(_msg, ...)` — it currently has NONE)
- Test: `test/cinder/catalog_test.exs` (broadcast shape); `test/cinder_web/live/status_live_test.exs` (row drop on `{:movie_deleted, id}`)

**Interfaces:**
- Consumes: `Catalog.subscribe/0` (`"movies"` topic), `Catalog.subscribe_series/0` (`"series"` topic).
- Produces:
  - `Catalog.broadcast_movie_deleted(id)` :: `:ok` — broadcasts `{:movie_deleted, id}` on `"movies"`.
  - `Catalog.broadcast_series_deleted(id)` :: `:ok` — broadcasts `{:series_deleted, id}` on `"series"`.
  - Message shapes `{:movie_deleted, id}` (on `"movies"`) and `{:series_deleted, id}` (on `"series"`) — Phase 2 `delete_movie/2`/`delete_series/2` fire these.
  - `StatusLive` now drops a deleted movie row and has a catch-all `handle_info/2`.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/catalog_test.exs`:
```elixir
  describe "delete broadcasts" do
    test "broadcast_movie_deleted/1 emits {:movie_deleted, id} on the movies topic" do
      Catalog.subscribe()
      assert :ok = Catalog.broadcast_movie_deleted(42)
      assert_receive {:movie_deleted, 42}
    end

    test "broadcast_series_deleted/1 emits {:series_deleted, id} on the series topic" do
      Catalog.subscribe_series()
      assert :ok = Catalog.broadcast_series_deleted(7)
      assert_receive {:series_deleted, 7}
    end
  end
```
And append to `test/cinder_web/live/status_live_test.exs`:
```elixir
  test "drops a movie row on a {:movie_deleted, id} broadcast", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9400, title: "Doomed Pic"})

    {:ok, lv, html} = live(conn, ~p"/status")
    assert html =~ "Doomed Pic"

    Catalog.broadcast_movie_deleted(movie.id)
    refute render(lv) =~ "Doomed Pic"
  end

  test "ignores an unrelated broadcast without crashing (catch-all handle_info)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/status")
    send(lv.pid, {:some_unhandled_topic, :payload})
    assert render(lv)  # still alive
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_test.exs` (`broadcast_movie_deleted/1 is undefined`) and `mix test test/cinder_web/live/status_live_test.exs` (the row-drop test fails — still rendered; the catch-all test crashes the LV on the unmatched message because StatusLive has no catch-all `handle_info`).
- [ ] **Step 3: Implement** —
  In `lib/cinder/catalog.ex`, after the private `broadcast/1` (~line 147) add:
```elixir
  @doc "Broadcasts `{:movie_deleted, id}` on the `\"movies\"` topic so open views drop the row."
  def broadcast_movie_deleted(id), do: broadcast({:movie_deleted, id})
```
  And after `broadcast_series/2` (~line 846, end of file) add:
```elixir
  @doc "Broadcasts `{:series_deleted, id}` on the `\"series\"` topic so open views drop the row."
  def broadcast_series_deleted(id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_deleted, id})
```
  In `lib/cinder_web/live/status_live.ex`, after the existing `handle_info({:movie_updated, movie}, ...)` clause (line 35) add the delete handler and a catch-all:
```elixir
  @impl true
  def handle_info({:movie_deleted, id}, socket) do
    movies = Enum.reject(socket.assigns.movies, &(&1.id == id))
    {:noreply, assign(socket, movies: movies)}
  end

  # Catch-all: an unmatched topic message (StatusLive had none) must not crash the view.
  def handle_info(_message, socket), do: {:noreply, socket}
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_test.exs test/cinder_web/live/status_live_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder/catalog.ex lib/cinder_web/live/status_live.ex test/cinder/catalog_test.exs test/cinder_web/live/status_live_test.exs && git commit -m "feat(catalog): delete broadcast helpers + StatusLive deleted-row handler & catch-all`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 9: `{:movie_deleted, id}` handlers in `WatchlistLive` + `MyRequestsLive`

**Files:**
- Modify: `lib/cinder_web/live/watchlist_live.ex` (add `handle_info({:movie_deleted, id}, ...)` before the existing catch-all at line 82)
- Modify: `lib/cinder_web/live/my_requests_live.ex` (catch-all at line 22 already reloads on every message — verify it drops a deleted movie; add an explicit clause only if needed)
- Test: `test/cinder_web/live/watchlist_live_test.exs`; `test/cinder_web/live/my_requests_live_test.exs`

**Interfaces:**
- Consumes: `{:movie_deleted, id}` (Task 8); `Catalog.subscribe/0`.
- Produces: `WatchlistLive` drops the deleted movie from its `:watchlist` assign; `MyRequestsLive` reloads (its existing catch-all already does — a deleted movie disappears from `Catalog.list_watchlist/0`, so the row's status badge drops, while the request row itself stays per spec).

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/watchlist_live_test.exs` (match the file's existing setup — it uses `register_and_log_in_user`/`register_and_log_in_admin`; check the head and reuse it):
```elixir
  test "drops a deleted movie from the watchlist on {:movie_deleted, id}", %{conn: conn} do
    {:ok, movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 9500, title: "Gone Soon"})

    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Gone Soon"

    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    refute render(lv) =~ "Gone Soon"
  end
```
And append to `test/cinder_web/live/my_requests_live_test.exs`:
```elixir
  test "survives a {:movie_deleted, id} broadcast (reloads, no crash)", %{conn: conn} do
    {:ok, movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 9600, title: "Vanish"})

    {:ok, lv, _html} = live(conn, ~p"/my-requests")
    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    assert render(lv)  # still alive after reload
  end
```
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/watchlist_live_test.exs` — the watchlist test fails: the existing catch-all `handle_info(_message, socket)` swallows `{:movie_deleted, id}` and leaves the row. (MyRequestsLive test should already PASS because its catch-all reloads — if it does, that's expected; keep the test as a regression guard.)
- [ ] **Step 3: Implement** — in `lib/cinder_web/live/watchlist_live.ex`, add a clause immediately before the catch-all `handle_info(_message, socket)` (line 82):
```elixir
  @impl true
  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, update(socket, :watchlist, fn wl -> Enum.reject(wl, &(&1.id == id)) end)}
  end
```
  `lib/cinder_web/live/my_requests_live.ex` needs NO change — its `handle_info(_message, socket), do: {:noreply, load(socket)}` (line 22) already reloads `list_watchlist/0` on every message, dropping the deleted movie's status badge. (Document this in the commit body.)
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/live/watchlist_live_test.exs test/cinder_web/live/my_requests_live_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/watchlist_live_test.exs test/cinder_web/live/my_requests_live_test.exs && git commit -m "feat(web): WatchlistLive drops deleted movie row; MyRequestsLive reload covers it`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 10: `{:series_deleted, id}` handlers in `SeriesDetailLive` + `CalendarLive`

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex` (add `handle_info({:series_deleted, id}, ...)` before the catch-all at line 65)
- Modify: `lib/cinder_web/live/calendar_live.ex` (add `handle_info({:series_deleted, _id}, ...)` before the catch-all at line 19)
- Test: `test/cinder_web/live/series_detail_live_test.exs`; `test/cinder_web/live/calendar_live_test.exs`

**Interfaces:**
- Consumes: `{:series_deleted, id}` (Task 8); `Catalog.subscribe_series/0`.
- Produces: `SeriesDetailLive` redirects to the series index (`~p"/series"`) with a flash when *its* series is deleted out from under it; `CalendarLive` re-derives rows (the deleted series' episodes vanish). Both keep their catch-all.

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/series_detail_live_test.exs` (reuse the file's existing series setup/fixture; if it builds a series via `Repo.insert!` or `Catalog.add_series_to_watchlist`, mirror that — check the head):
```elixir
  test "redirects to /series when the open series is deleted", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7001, title: "Detail Show"})

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    Cinder.Catalog.broadcast_series_deleted(series.id)
    assert_redirect(lv, ~p"/series")
  end

  test "ignores a {:series_deleted, id} for a different series", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7002, title: "Stay Show"})

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    Cinder.Catalog.broadcast_series_deleted(series.id + 999)
    assert render(lv) =~ "Stay Show"
  end
```
And append to `test/cinder_web/live/calendar_live_test.exs`:
```elixir
  test "survives a {:series_deleted, id} broadcast (re-derives, no crash)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/calendar")
    Cinder.Catalog.broadcast_series_deleted(123)
    assert render(lv)  # still alive
  end
```
*(Match the route paths and conn setup to each test file's existing helpers — `register_and_log_in_admin` for the `:admin` `series/:id` view; `/calendar` per its router entry.)*
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/series_detail_live_test.exs` — the redirect test fails: the existing catch-all `handle_info(_message, socket)` swallows `{:series_deleted, id}` (no redirect). (CalendarLive's catch-all already re-derives, so its test may pass — keep it as a guard.)
- [ ] **Step 3: Implement** — in `lib/cinder_web/live/series_detail_live.ex`, add immediately before the catch-all (line 65):
```elixir
  def handle_info({:series_deleted, id}, socket) do
    if socket.assigns.series.id == id do
      {:noreply,
       socket
       |> put_flash(:info, "Series deleted.")
       |> push_navigate(to: ~p"/series")}
    else
      {:noreply, socket}
    end
  end
```
  *(Verify the assign key — this view assigns the loaded series; the mount at line 17 sets it. If the assign is named other than `:series`, adjust `socket.assigns.series.id` to match what mount assigns.)*
  In `lib/cinder_web/live/calendar_live.ex`, add before the catch-all (line 19):
```elixir
  def handle_info({:series_deleted, _id}, socket), do: {:noreply, assign_rows(socket)}
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/live/series_detail_live_test.exs test/cinder_web/live/calendar_live_test.exs`.
- [ ] **Step 5: Commit** — `git add lib/cinder_web/live/series_detail_live.ex lib/cinder_web/live/calendar_live.ex test/cinder_web/live/series_detail_live_test.exs test/cinder_web/live/calendar_live_test.exs && git commit -m "feat(web): series-deleted handlers (SeriesDetail redirects, Calendar re-derives)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---


### Task 11: Pin `foreign_keys: :on` in Repo config + FK cascade proof tests

**Files:**
- Modify: `config/dev.exs` (add `foreign_keys: :on` to the `Cinder.Repo` block, near `journal_mode`/`busy_timeout`)
- Modify: `config/test.exs` (add `foreign_keys: :on` to the `Cinder.Repo` block, near `journal_mode`/`busy_timeout`)
- Test: `test/cinder/accounts_test.exs` (user→requests cascade); `test/cinder/catalog_series_test.exs` (series→seasons→episodes cascade)

**Interfaces:**
- Consumes: `Repo.delete/1`; `Cinder.Requests.Request`, `Cinder.Catalog.{Series, Season, Episode}` schemas; FK `on_delete` clauses already in the migrations (`requests.user_id :delete_all`, `seasons.series_id :delete_all`, `episodes.season_id :delete_all`, `episodes.grab_id :nilify_all`).
- Produces: `foreign_keys: :on` pinned in dev + test Repo config (defends against an ecto_sqlite3/exqlite default-drift, same rationale as the pinned `journal_mode`/`busy_timeout`). Proven cascade behavior Phase 1 (`delete_user`) and Phase 2 (`delete_series`) rely on.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs`:
```elixir
  describe "FK cascade (foreign_keys: :on)" do
    test "deleting a user cascade-deletes their requests" do
      user = user_fixture()

      request =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: user.id,
          target_type: "movie",
          target_id: 555,
          status: :pending
        })

      assert {:ok, _} = Repo.delete(user)
      refute Repo.get(Cinder.Requests.Request, request.id)
    end
  end
```
And append to `test/cinder/catalog_series_test.exs` (it aliases `Cinder.Catalog.{...}` — reuse; mirror its fixture style with `Repo.insert!`):
```elixir
  describe "FK cascade (foreign_keys: :on)" do
    test "deleting a series cascade-deletes its seasons and episodes" do
      series = Repo.insert!(%Series{tmdb_id: 8001, title: "Cascade Show"})
      season = Repo.insert!(%Season{series_id: series.id, season_number: 1})

      episode =
        Repo.insert!(%Episode{season_id: season.id, episode_number: 1, monitored: true})

      assert {:ok, _} = Repo.delete(series)
      refute Repo.get(Season, season.id)
      refute Repo.get(Episode, episode.id)
    end
  end
```
*(Confirm `Series`, `Season`, `Episode` are aliased in `catalog_series_test.exs` — if it aliases a subset, use fully-qualified `Cinder.Catalog.Season`/`Episode`. The file uses `use Cinder.DataCase`, which imports `Repo`.)*
- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/accounts_test.exs test/cinder/catalog_series_test.exs`. NOTE: ecto_sqlite3 enables `foreign_keys: :on` by default, so the cascade tests may already PASS on the current code. That is acceptable and expected — these tests are the *proof* the spec demands; their real job is to fail loudly if the pragma ever drifts off. If they pass before the config edit, treat Step 2 as "tests run green, pragma not yet pinned" and proceed to pin it in Step 3 (the defend-against-drift deliverable). If a future ecto_sqlite3 default flipped them off, they'd RED here.
- [ ] **Step 3: Implement** — in `config/dev.exs`, in the `config :cinder, Cinder.Repo` block, add after `busy_timeout: 5_000,`:
```elixir
  # Pinned for the same defend-against-dep-default-drift reason as journal_mode/
  # busy_timeout: the admin delete cascades (requests on user delete; seasons/
  # episodes on series delete) depend on SQLite enforcing FKs. On by ecto_sqlite3
  # default today, pinned so a dep change can't silently disable it.
  foreign_keys: :on,
```
  In `config/test.exs`, in the `config :cinder, Cinder.Repo` block, add after `busy_timeout: 5_000,`:
```elixir
  foreign_keys: :on,
```
- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/accounts_test.exs test/cinder/catalog_series_test.exs`, then the full suite `mix test` to confirm the pragma pin broke nothing.
- [ ] **Step 5: Commit** — `git add config/dev.exs config/test.exs test/cinder/accounts_test.exs test/cinder/catalog_series_test.exs && git commit -m "chore(repo): pin foreign_keys: :on + FK cascade proof tests (user/series deletes)`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`

---

### Task 12: Phase-0 green-gate sweep

**Files:** none (verification only).

**Interfaces:** Consumes everything above. Produces a clean Phase 0 baseline for Phases 1–3.

- [ ] **Step 1: Write the failing test** — N/A (gate task).
- [ ] **Step 2: Run it, expect FAIL** — N/A.
- [ ] **Step 3: Implement** — N/A.
- [ ] **Step 4: Run, expect PASS** — `mix test` (full gate: compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite). If `mix test` does not chain those, run them explicitly: `mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && mix test`. Credo/warnings traps to confirm: `@moduledoc` on `Cinder.Audit` + `Cinder.Audit.AdminAudit` (present); `@impl true` on the new `remove/2` impls (present); alias ordering; no unused vars; runtime `Application.fetch_env!/2` (no new `compile_env!`); StatusLive keeps both its catch-all `handle_event/3` (unchanged) and the new catch-all `handle_info/2`.
- [ ] **Step 5: Commit** — nothing to commit (sweep only). If `mix format` rewrote anything, `git add -A && git commit -m "style: mix format Phase 0`<br>`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`<br>`Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"`.

---

# Phase 1 — Users CRUD

### Task 1: `Accounts.count_admins/0` + `Accounts.create_user/1`

**Files:**
- Modify: `lib/cinder/accounts.ex` (add `count_admins/0` and `create_user/1` after `register_user/1`, ~lines 70-93 region)
- Test: `test/cinder/accounts_test.exs` (add `describe "count_admins/0"` and `describe "create_user/1"` blocks)

**Interfaces:**
- Consumes: `User.registration_changeset/2,3`, `User.email_changeset/3` (existing); `Cinder.AccountsFixtures.{user_fixture,admin_fixture}/0` (existing).
- Produces:
  - `Accounts.count_admins/0 :: non_neg_integer` — counts users with `role: :admin`.
  - `Accounts.create_user/1 :: {:ok, %User{}} | {:error, %Ecto.Changeset{}}` — accepts `%{email, password, password_confirmation, role}`; applies `role` + `confirmed_at` via `put_change` (never castable); validations via `registration_changeset`. `role` defaults to `:user` when absent.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs` (after the existing last `describe` block, before the final `end`):

```elixir
  describe "count_admins/0" do
    test "counts only admins" do
      _user = user_fixture()
      _admin = admin_fixture()
      assert Accounts.count_admins() == 1
    end

    test "is zero when there are no users" do
      assert Accounts.count_admins() == 0
    end
  end

  describe "create_user/1" do
    test "creates a confirmed user with the default :user role" do
      email = unique_user_email()

      assert {:ok, %User{} = user} =
               Accounts.create_user(%{
                 email: email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert user.email == email
      assert user.role == :user
      assert user.confirmed_at
      assert is_binary(user.hashed_password)
    end

    test "creates an admin when role: :admin is given" do
      assert {:ok, %User{role: :admin}} =
               Accounts.create_user(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password(),
                 role: :admin
               })
    end

    test "rejects a password confirmation mismatch" do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 email: unique_user_email(),
                 password: valid_user_password(),
                 password_confirmation: "nope nope nope"
               })

      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "rejects a duplicate email" do
      existing = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(%{
                 email: existing.email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'` — expect `(UndefinedFunctionError) function Cinder.Accounts.count_admins/0 is undefined` / `create_user/1 is undefined`.

- [ ] **Step 3: Implement** — in `lib/cinder/accounts.ex`, add after the `register_user/1` function (it ends with the `Repo.transaction` block) and `admin_exists?/0`:

```elixir
  @doc "Counts users with the `:admin` role."
  def count_admins do
    Repo.aggregate(from(u in User, where: u.role == :admin), :count)
  end

  @doc """
  Admin-creates a fully-confirmed user. `:role` (default `:user`) and
  `:confirmed_at` are applied via `put_change` — never castable — while email and
  password are validated by `registration_changeset/2`.
  """
  def create_user(attrs) do
    role = Map.get(attrs, :role, :user)

    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Ecto.Changeset.put_change(:role, role)
    |> Repo.insert()
  end
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder/accounts.ex test/cinder/accounts_test.exs && git commit -m "feat(accounts): add count_admins/0 and admin create_user/1"'`

---

### Task 2: `Accounts.update_user_role/2` (transactional last-admin guard + audit)

**Files:**
- Modify: `lib/cinder/accounts.ex` (add `update_user_role/2` after `create_user/1`; add `alias Cinder.Audit` near top)
- Test: `test/cinder/accounts_test.exs` (add `describe "update_user_role/2"`)

**Interfaces:**
- Consumes:
  - `Cinder.Audit.log(actor, action, entity, detail \\ %{}) :: {:ok, %AdminAudit{}} | {:error, %Ecto.Changeset{}}` (Phase 0) — MUST be called INSIDE the caller's own `Repo.transaction`, after the guard passes, before commit.
  - `Accounts.count_admins/0` (Task 1).
- Produces:
  - `Accounts.update_user_role/2 :: {:ok, %User{}} | {:error, :last_admin} | {:error, %Ecto.Changeset{}}`. Signature: `update_user_role(actor, target, role)` — see note. **Decision:** the spec lists `update_user_role/2`; the actor is required for audit, so the LiveView passes `current_scope.user`. Implement as `update_user_role(%User{} = actor, %User{} = target, role)` (arity 3) and keep the spec's intent (audited). Re-count admins AFTER the write inside the transaction; rollback `{:error, :last_admin}` if it would hit zero.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs`:

```elixir
  describe "update_user_role/2" do
    test "promotes a user to admin and audits it" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:ok, %User{role: :admin, id: tid}} =
               Accounts.update_user_role(actor, target, :admin)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^tid)
      assert audit.action == "update_user_role"
      assert audit.entity_type == "User"
      assert audit.actor_id == actor.id
      assert audit.detail["role"] == "admin"
    end

    test "demotes a second admin to user" do
      actor = admin_fixture()
      target = admin_fixture()
      assert {:ok, %User{role: :user}} = Accounts.update_user_role(actor, target, :user)
    end

    test "refuses to demote the last admin and writes no audit row" do
      actor = admin_fixture()

      assert {:error, :last_admin} = Accounts.update_user_role(actor, actor, :user)
      assert Repo.reload!(actor).role == :admin
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs:LINE'` (the `describe "update_user_role/2"` line) — expect `function Cinder.Accounts.update_user_role/3 is undefined`.

- [ ] **Step 3: Implement** — add `alias Cinder.Audit` to the alias block at the top of `lib/cinder/accounts.ex` (after `alias Cinder.Accounts.{User, UserNotifier, UserToken}`), then add:

```elixir
  @doc """
  Sets a user's role. Refuses to demote the last admin: the admin count is
  re-checked AFTER the write inside one transaction (a write that would drop the
  count to zero rolls back as `{:error, :last_admin}`). Writes an audit row in
  the same transaction.
  """
  def update_user_role(%User{} = actor, %User{} = target, role) when role in [:admin, :user] do
    Repo.transaction(fn ->
      {:ok, updated} =
        target |> Ecto.Changeset.change(role: role) |> Repo.update()

      if count_admins() == 0 do
        Repo.rollback(:last_admin)
      end

      {:ok, _audit} =
        Audit.log(actor, "update_user_role", updated, %{role: to_string(role)})

      updated
    end)
  end
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder/accounts.ex test/cinder/accounts_test.exs && git commit -m "feat(accounts): update_user_role/3 with transactional last-admin guard + audit"'`

---

### Task 3: `Accounts.admin_update_email/2` (reuse `email_changeset`, audited)

**Files:**
- Modify: `lib/cinder/accounts.ex` (add `admin_update_email/3` after `update_user_role/3`)
- Test: `test/cinder/accounts_test.exs` (add `describe "admin_update_email/2"`)

**Interfaces:**
- Consumes: `User.email_changeset/2,3` (existing, validates uniqueness + format + "did not change"); `Cinder.Audit.log/4` (Phase 0).
- Produces: `Accounts.admin_update_email(actor, target, attrs) :: {:ok, %User{}} | {:error, %Ecto.Changeset{}}` — direct DB update of email (no token round-trip), audited in-txn.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs`:

```elixir
  describe "admin_update_email/2" do
    test "changes the email directly and audits it" do
      actor = admin_fixture()
      target = user_fixture()
      new_email = unique_user_email()

      assert {:ok, %User{} = updated} =
               Accounts.admin_update_email(actor, target, %{email: new_email})

      assert updated.email == new_email

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^target.id)
      assert audit.action == "admin_update_email"
      assert audit.detail["email"] == new_email
    end

    test "rejects an invalid email" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:error, changeset} =
               Accounts.admin_update_email(actor, target, %{email: "not an email"})

      assert %{email: _} = errors_on(changeset)
    end

    test "rejects an unchanged email" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:error, changeset} =
               Accounts.admin_update_email(actor, target, %{email: target.email})

      assert %{email: ["did not change"]} = errors_on(changeset)
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs:LINE'` — expect `function Cinder.Accounts.admin_update_email/3 is undefined`.

- [ ] **Step 3: Implement** — add to `lib/cinder/accounts.ex`:

```elixir
  @doc """
  Admin-edits a user's email directly (no confirmation token round-trip), reusing
  `User.email_changeset/2` for validation. Audited in-transaction.
  """
  def admin_update_email(%User{} = actor, %User{} = target, attrs) do
    changeset = User.email_changeset(target, attrs)

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated} ->
          {:ok, _audit} =
            Audit.log(actor, "admin_update_email", updated, %{email: updated.email})

          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder/accounts.ex test/cinder/accounts_test.exs && git commit -m "feat(accounts): admin_update_email/3 (direct edit, audited)"'`

---

### Task 4: `Accounts.admin_reset_password/2` (set password + expire tokens, audited)

**Files:**
- Modify: `lib/cinder/accounts.ex` (add `admin_reset_password/3` after `admin_update_email/3`)
- Test: `test/cinder/accounts_test.exs` (add `describe "admin_reset_password/2"`)

**Interfaces:**
- Consumes: `User.password_changeset/2` (existing); the private `update_user_and_delete_all_tokens/1` (existing, returns `{:ok, {user, expired_tokens}}`); `Cinder.Audit.log/4`.
- Produces: `Accounts.admin_reset_password(actor, target, attrs) :: {:ok, %User{}} | {:error, %Ecto.Changeset{}}` — sets the password directly and expires ALL the target's tokens; audited.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs`:

```elixir
  describe "admin_reset_password/2" do
    test "sets a new password, expires the target's sessions, and audits it" do
      actor = admin_fixture()
      target = user_fixture() |> set_password()
      old_token = Accounts.generate_user_session_token(target)

      assert {:ok, %User{} = updated} =
               Accounts.admin_reset_password(actor, target, %{
                 password: "brand new password!",
                 password_confirmation: "brand new password!"
               })

      assert Accounts.get_user_by_email_and_password(updated.email, "brand new password!")
      refute Accounts.get_user_by_session_token(old_token)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^target.id)
      assert audit.action == "admin_reset_password"
    end

    test "rejects a too-short password" do
      actor = admin_fixture()
      target = user_fixture()

      assert {:error, changeset} =
               Accounts.admin_reset_password(actor, target, %{
                 password: "short",
                 password_confirmation: "short"
               })

      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs:LINE'` — expect `function Cinder.Accounts.admin_reset_password/3 is undefined`.

- [ ] **Step 3: Implement** — add to `lib/cinder/accounts.ex`. Note `update_user_and_delete_all_tokens/1` runs its own `Repo.transact`; the audit row is written in the same outer transaction wrapping it:

```elixir
  @doc """
  Admin-resets a user's password directly and expires ALL their tokens (logging
  them out everywhere) via `update_user_and_delete_all_tokens/1`. Audited in the
  same transaction.
  """
  def admin_reset_password(%User{} = actor, %User{} = target, attrs) do
    changeset = User.password_changeset(target, attrs)

    Repo.transaction(fn ->
      case update_user_and_delete_all_tokens(changeset) do
        {:ok, {user, _expired}} ->
          {:ok, _audit} = Audit.log(actor, "admin_reset_password", user, %{})
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder/accounts.ex test/cinder/accounts_test.exs && git commit -m "feat(accounts): admin_reset_password/3 (set password + expire tokens, audited)"'`

---

### Task 5: `Accounts.delete_user/1` (last-admin + self-delete guards, cascade, audited)

**Files:**
- Modify: `lib/cinder/accounts.ex` (add `delete_user/2` after `admin_reset_password/3`)
- Test: `test/cinder/accounts_test.exs` (add `describe "delete_user/1"`); requires building a request row — use `Repo.insert!` directly on the Request struct.

**Interfaces:**
- Consumes:
  - `Cinder.Audit.log/4` (Phase 0) — logged BEFORE `Repo.delete` (entity must be persisted to read `entity.id`/email), inside the transaction.
  - `Accounts.count_admins/0` (Task 1).
  - FK cascades (Phase 0): `requests.user_id :delete_all`, `requests.approved_by_id :nilify_all`, `foreign_keys: :on` pinned in config/test.exs.
- Produces: `Accounts.delete_user(actor, target) :: {:ok, %User{}} | {:error, :last_admin} | {:error, :self_delete}` — refuses last admin AND self; cascades requests; audit `detail` records deleted email + that request history cascaded. Self-delete guarded by comparing `actor.id == target.id` (server-side actor, never a client id).

- [ ] **Step 1: Write the failing test** — append to `test/cinder/accounts_test.exs`. Build a request via `Repo.insert!` (no request fixture module exists):

```elixir
  describe "delete_user/1" do
    test "deletes a user, cascades their requests, and audits it" do
      actor = admin_fixture()
      target = user_fixture()

      req =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: target.id,
          tmdb_id: 603,
          target_type: "movie",
          title: "The Matrix",
          status: :pending
        })

      assert {:ok, %User{id: tid}} = Accounts.delete_user(actor, target)
      refute Repo.get(User, tid)
      refute Repo.get(Cinder.Requests.Request, req.id)

      audit = Repo.one!(from a in Cinder.Audit.AdminAudit, where: a.entity_id == ^tid)
      assert audit.action == "delete_user"
      assert audit.entity_type == "User"
      assert audit.detail["email"] == target.email
      assert audit.detail["cascaded_requests"] == true
    end

    test "nilifies approved_by_id on requests the deleted user approved" do
      actor = admin_fixture()
      approver = admin_fixture()
      requester = user_fixture()

      req =
        Repo.insert!(%Cinder.Requests.Request{
          user_id: requester.id,
          approved_by_id: approver.id,
          tmdb_id: 27205,
          target_type: "movie",
          title: "Inception",
          status: :approved
        })

      assert {:ok, _} = Accounts.delete_user(actor, approver)
      assert Repo.get(Cinder.Requests.Request, req.id).approved_by_id == nil
    end

    test "refuses to delete the last admin and writes no audit row" do
      actor = admin_fixture()
      other = admin_fixture()
      # demote `other` so `actor` is the only admin
      {:ok, _} = Accounts.update_user_role(actor, other, :user)
      Repo.delete_all(Cinder.Audit.AdminAudit)

      assert {:error, :last_admin} = Accounts.delete_user(other, actor)
      assert Repo.reload!(actor)
      assert Repo.aggregate(Cinder.Audit.AdminAudit, :count) == 0
    end

    test "refuses to delete your own account" do
      actor = admin_fixture()
      _second = admin_fixture()
      assert {:error, :self_delete} = Accounts.delete_user(actor, actor)
      assert Repo.reload!(actor)
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs:LINE'` — expect `function Cinder.Accounts.delete_user/2 is undefined`.

- [ ] **Step 3: Implement** — add to `lib/cinder/accounts.ex`. Self-delete checked first (cheap, no write); then delete, audit, then re-count admins inside the transaction:

```elixir
  @doc """
  Deletes a user. Refuses self-delete and refuses to delete the last admin (the
  admin count is re-checked AFTER the delete inside one transaction). The DB
  cascades the user's requests (`user_id :delete_all`) and nilifies any
  `approved_by_id` links. Audited in the same transaction, before the delete, so
  the audit `detail` can record the deleted email.
  """
  def delete_user(%User{} = actor, %User{} = target) do
    if actor.id == target.id do
      {:error, :self_delete}
    else
      Repo.transaction(fn ->
        {:ok, _audit} =
          Audit.log(actor, "delete_user", target, %{
            email: target.email,
            cascaded_requests: true
          })

        {:ok, deleted} = Repo.delete(target)

        if count_admins() == 0 do
          Repo.rollback(:last_admin)
        end

        deleted
      end)
    end
  end
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/accounts_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder/accounts.ex test/cinder/accounts_test.exs && git commit -m "feat(accounts): delete_user/2 (last-admin + self-delete guards, cascade, audited)"'`

---

### Task 6: `UsersLive` create form

**Files:**
- Modify: `lib/cinder_web/live/users_live.ex` — `mount/3` (add `form` + `creating` assigns), `handle_event/3` (add `"start_create"`, `"validate_create"`, `"create"`), `render/1` (add create panel above the list).
- Test: `test/cinder_web/live/users_live_test.exs` (add create interaction tests)

**Interfaces:**
- Consumes: `Accounts.create_user/1` (Task 1); `Accounts.change_user_email/1` is not suitable — use a plain form map. The form is rendered from `to_form/1` over a params map (email/password/password_confirmation/role).
- Produces: nothing consumed by later tasks (LiveView leaf).

- [ ] **Step 1: Write the failing test** — append a test to `test/cinder_web/live/users_live_test.exs` (inside the module, before the final `end`):

```elixir
  test "admin creates a new user", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)
    email = Cinder.AccountsFixtures.unique_user_email()

    {:ok, lv, _html} = live(conn, ~p"/users")

    lv |> element("button", "New user") |> render_click()

    lv
    |> form("#create-user-form", %{
      "user" => %{
        "email" => email,
        "password" => Cinder.AccountsFixtures.valid_user_password(),
        "password_confirmation" => Cinder.AccountsFixtures.valid_user_password(),
        "role" => "user"
      }
    })
    |> render_submit()

    assert Cinder.Accounts.get_user_by_email(email)
    assert render(lv) =~ email
  end

  test "create form shows validation errors", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("button", "New user") |> render_click()

    html =
      lv
      |> form("#create-user-form", %{
        "user" => %{
          "email" => "bad",
          "password" => "short",
          "password_confirmation" => "short",
          "role" => "user"
        }
      })
      |> render_submit()

    assert html =~ "must have the @ sign"
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'` — expect failure: no element matching `button "New user"` / `#create-user-form`.

- [ ] **Step 3: Implement** — edit `lib/cinder_web/live/users_live.ex`. Replace the `mount/3` and add the create events + a render panel. New `mount/3`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(users: Accounts.list_users(), creating: false)
     |> assign_create_form()}
  end

  defp assign_create_form(socket, params \\ %{"role" => "user"}) do
    assign(socket, :create_form, to_form(params, as: :user))
  end
```

Add these `handle_event/3` clauses ABOVE the existing `handle_event("set_quota", ...)` (keep the catch-all `handle_event(_event, _params, socket)` LAST):

```elixir
  def handle_event("start_create", _params, socket) do
    {:noreply, socket |> assign(creating: true) |> assign_create_form()}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, creating: false)}
  end

  def handle_event("validate_create", %{"user" => params}, socket) do
    {:noreply, assign_create_form(socket, params)}
  end

  def handle_event("create", %{"user" => params}, socket) do
    attrs = %{
      email: params["email"],
      password: params["password"],
      password_confirmation: params["password_confirmation"],
      role: role_atom(params["role"])
    }

    case Accounts.create_user(attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(users: Accounts.list_users(), creating: false)
         |> assign_create_form()
         |> put_flash(:info, "User created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: :user))}
    end
  end
```

Add a private role parser near `parse_quota/1`:

```elixir
  defp role_atom("admin"), do: :admin
  defp role_atom(_), do: :user
```

In `render/1`, insert this block immediately after the `<.header>...</.header>` close and before the `<ul ...>`:

```elixir
      <div class="mb-6">
        <button :if={!@creating} class="btn btn-primary btn-sm" phx-click="start_create">
          New user
        </button>
        <.form
          :if={@creating}
          id="create-user-form"
          for={@create_form}
          phx-change="validate_create"
          phx-submit="create"
          class="card bg-base-200 p-4 space-y-2"
        >
          <.input field={@create_form[:email]} type="email" label="Email" />
          <.input field={@create_form[:password]} type="password" label="Password" />
          <.input
            field={@create_form[:password_confirmation]}
            type="password"
            label="Confirm password"
          />
          <.input
            field={@create_form[:role]}
            type="select"
            label="Role"
            options={[{"User", "user"}, {"Admin", "admin"}]}
          />
          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm" type="submit">Create</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_create">
              Cancel
            </button>
          </div>
        </.form>
      </div>
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder_web/live/users_live.ex test/cinder_web/live/users_live_test.exs && git commit -m "feat(users-live): admin create-user form"'`

---

### Task 7: `UsersLive` edit-email + role toggle

**Files:**
- Modify: `lib/cinder_web/live/users_live.ex` — `mount/3` (add `editing_email` assign), `handle_event/3` (add `"start_edit_email"`, `"cancel_edit_email"`, `"save_email"`, `"toggle_role"`), `render/1` (per-row email-edit panel + role toggle button).
- Test: `test/cinder_web/live/users_live_test.exs`

**Interfaces:**
- Consumes: `Accounts.admin_update_email/3` (Task 3); `Accounts.update_user_role/3` (Task 2); `socket.assigns.current_scope.user` (the acting admin, set by `:mount_current_scope` on_mount).
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/users_live_test.exs`:

```elixir
  test "admin edits a user's email", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)
    new_email = Cinder.AccountsFixtures.unique_user_email()

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#edit-email-btn-#{user.id}") |> render_click()

    lv
    |> form("#edit-email-form-#{user.id}", %{"user" => %{"email" => new_email}})
    |> render_submit()

    assert Cinder.Accounts.get_user!(user.id).email == new_email
  end

  test "admin toggles a user's role", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#role-btn-#{user.id}") |> render_click()

    assert Cinder.Accounts.get_user!(user.id).role == :admin
  end

  test "demoting the last admin flashes an error and does not change the role", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    html = lv |> element("#role-btn-#{admin.id}") |> render_click()

    assert html =~ "last admin"
    assert Cinder.Accounts.get_user!(admin.id).role == :admin
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'` — expect no `#edit-email-btn-*` / `#role-btn-*` element.

- [ ] **Step 3: Implement** — in `lib/cinder_web/live/users_live.ex`, extend the `mount/3` assign chain to add `editing_email: nil`:

```elixir
     |> assign(users: Accounts.list_users(), creating: false, editing_email: nil)
```

Add these `handle_event/3` clauses above the catch-all:

```elixir
  def handle_event("start_edit_email", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_email: String.to_integer(id))}
  end

  def handle_event("cancel_edit_email", _params, socket) do
    {:noreply, assign(socket, editing_email: nil)}
  end

  def handle_event("save_email", %{"_id" => id, "user" => %{"email" => email}}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    actor = socket.assigns.current_scope.user

    case Accounts.admin_update_email(actor, user, %{email: email}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(users: Accounts.list_users(), editing_email: nil)
         |> put_flash(:info, "Email updated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't update email — check the address.")}
    end
  end

  def handle_event("toggle_role", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    actor = socket.assigns.current_scope.user
    new_role = if user.role == :admin, do: :user, else: :admin

    case Accounts.update_user_role(actor, user, new_role) do
      {:ok, _} ->
        {:noreply, assign(socket, users: Accounts.list_users())}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, "Can't demote the last admin.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't change role.")}
    end
  end
```

In `render/1`, inside the `<li>` for each user, replace the static role badge line `<span class="badge badge-sm">{u.role}</span>` with a clickable role toggle, and add the email-edit affordance. Replace the `<div class="flex items-center gap-3">` block contents so it becomes:

```elixir
          <div class="flex items-center gap-3 flex-wrap">
            <span class="font-semibold">{u.email}</span>
            <button
              id={"role-btn-#{u.id}"}
              class="badge badge-sm"
              phx-click="toggle_role"
              phx-value-id={u.id}
              title="Toggle admin/user"
            >
              {u.role}
            </button>
            <button
              id={"edit-email-btn-#{u.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="start_edit_email"
              phx-value-id={u.id}
            >
              Edit email
            </button>
            <form
              id={"quota-#{u.id}"}
              phx-submit="set_quota"
              class="ml-auto flex items-center gap-2"
            >
              <input type="hidden" name="_id" value={u.id} />
              <label class="text-sm" for={"quota-input-#{u.id}"}>Quota</label>
              <input
                id={"quota-input-#{u.id}"}
                type="number"
                name="quota"
                min="0"
                value={u.request_quota}
                class="input input-sm w-24"
                placeholder="∞"
              />
              <button class="btn btn-sm">Save</button>
            </form>
          </div>
          <.form
            :if={@editing_email == u.id}
            id={"edit-email-form-#{u.id}"}
            for={to_form(%{"email" => u.email}, as: :user)}
            phx-submit="save_email"
            class="mt-2 flex items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <input
              type="email"
              name="user[email]"
              value={u.email}
              class="input input-sm input-bordered"
            />
            <button class="btn btn-primary btn-sm" type="submit">Save email</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_edit_email">
              Cancel
            </button>
          </.form>
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder_web/live/users_live.ex test/cinder_web/live/users_live_test.exs && git commit -m "feat(users-live): edit-email and role-toggle controls"'`

---

### Task 8: `UsersLive` reset-password + delete (in-LiveView confirm panel)

**Files:**
- Modify: `lib/cinder_web/live/users_live.ex` — `mount/3` (add `confirming_delete` + `resetting_pw` assigns), `handle_event/3` (add `"start_reset_pw"`, `"cancel_reset_pw"`, `"reset_pw"`, `"start_delete"`, `"cancel_delete"`, `"delete"`), `render/1` (reset-pw form + confirm-delete panel mirroring RequestsLive's `denying`).
- Test: `test/cinder_web/live/users_live_test.exs`

**Interfaces:**
- Consumes: `Accounts.admin_reset_password/3` (Task 4); `Accounts.delete_user/2` (Task 5); `socket.assigns.current_scope.user`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/users_live_test.exs`:

```elixir
  test "admin resets a user's password", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#reset-pw-btn-#{user.id}") |> render_click()

    lv
    |> form("#reset-pw-form-#{user.id}", %{
      "user" => %{
        "password" => "a fresh password!",
        "password_confirmation" => "a fresh password!"
      }
    })
    |> render_submit()

    assert Cinder.Accounts.get_user_by_email_and_password(user.email, "a fresh password!")
  end

  test "admin deletes a user via the confirm panel", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{user.id}") |> render_click()
    lv |> element("#confirm-delete-#{user.id}") |> render_click()

    refute Cinder.Accounts.get_user_by_email(user.email)
    refute render(lv) =~ user.email
  end

  test "deleting your own account flashes an error", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    _second = Cinder.AccountsFixtures.admin_fixture()
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{admin.id}") |> render_click()
    html = lv |> element("#confirm-delete-#{admin.id}") |> render_click()

    assert html =~ "your own account"
    assert Cinder.Accounts.get_user!(admin.id)
  end

  test "deleting the last admin flashes an error", %{conn: conn} do
    admin = Cinder.AccountsFixtures.admin_fixture()
    other = Cinder.AccountsFixtures.admin_fixture()
    {:ok, _} = Cinder.Accounts.update_user_role(admin, other, :user)
    conn = log_in_user(conn, other)

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#delete-btn-#{admin.id}") |> render_click()
    html = lv |> element("#confirm-delete-#{admin.id}") |> render_click()

    assert html =~ "last admin"
    assert Cinder.Accounts.get_user!(admin.id)
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'` — expect no `#reset-pw-btn-*` / `#delete-btn-*` element.

- [ ] **Step 3: Implement** — extend `mount/3` assigns to add `confirming_delete: nil, resetting_pw: nil`:

```elixir
     |> assign(
       users: Accounts.list_users(),
       creating: false,
       editing_email: nil,
       resetting_pw: nil,
       confirming_delete: nil
     )
```

Add these `handle_event/3` clauses above the catch-all:

```elixir
  def handle_event("start_reset_pw", %{"id" => id}, socket) do
    {:noreply, assign(socket, resetting_pw: String.to_integer(id))}
  end

  def handle_event("cancel_reset_pw", _params, socket) do
    {:noreply, assign(socket, resetting_pw: nil)}
  end

  def handle_event("reset_pw", %{"_id" => id, "user" => params}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    actor = socket.assigns.current_scope.user

    attrs = %{
      password: params["password"],
      password_confirmation: params["password_confirmation"]
    }

    case Accounts.admin_reset_password(actor, user, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(resetting_pw: nil)
         |> put_flash(:info, "Password reset — the user's sessions were ended.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Password must be at least 12 characters.")}
    end
  end

  def handle_event("start_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_delete: String.to_integer(id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming_delete: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    actor = socket.assigns.current_scope.user

    case Accounts.delete_user(actor, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(users: Accounts.list_users(), confirming_delete: nil)
         |> put_flash(:info, "User deleted.")}

      {:error, :self_delete} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, "You can't delete your own account.")}

      {:error, :last_admin} ->
        {:noreply,
         socket
         |> assign(confirming_delete: nil)
         |> put_flash(:error, "Can't delete the last admin.")}
    end
  end
```

In `render/1`, inside each user `<li>`, after the email-edit `<.form>` block, add the reset-pw + delete controls and their panels:

```elixir
          <div class="mt-2 flex items-center gap-2 flex-wrap">
            <button
              id={"reset-pw-btn-#{u.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="start_reset_pw"
              phx-value-id={u.id}
            >
              Reset password
            </button>
            <button
              :if={@confirming_delete != u.id}
              id={"delete-btn-#{u.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="start_delete"
              phx-value-id={u.id}
            >
              Delete
            </button>
            <span :if={@confirming_delete == u.id} class="flex items-center gap-2">
              <span class="text-sm">Delete {u.email}? Requests cascade.</span>
              <button
                id={"confirm-delete-#{u.id}"}
                class="btn btn-error btn-xs"
                phx-click="delete"
                phx-value-id={u.id}
              >
                Confirm delete
              </button>
              <button class="btn btn-ghost btn-xs" phx-click="cancel_delete">Cancel</button>
            </span>
          </div>
          <.form
            :if={@resetting_pw == u.id}
            id={"reset-pw-form-#{u.id}"}
            for={to_form(%{}, as: :user)}
            phx-submit="reset_pw"
            class="mt-2 flex items-center gap-2"
          >
            <input type="hidden" name="_id" value={u.id} />
            <input
              type="password"
              name="user[password]"
              placeholder="New password"
              class="input input-sm input-bordered"
            />
            <input
              type="password"
              name="user[password_confirmation]"
              placeholder="Confirm"
              class="input input-sm input-bordered"
            />
            <button class="btn btn-primary btn-sm" type="submit">Set password</button>
            <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_reset_pw">
              Cancel
            </button>
          </.form>
```

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'`

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add lib/cinder_web/live/users_live.ex test/cinder_web/live/users_live_test.exs && git commit -m "feat(users-live): reset-password and confirm-delete panels"'`

---

### Task 9: `/users` non-admin authorization coverage + full gate

**Files:**
- Test: `test/cinder_web/live/users_live_test.exs` (add a non-admin redirect test)
- No production code change expected (route already in `:admin` session); this task closes the spec's "LiveView authorization test for every changed admin surface" requirement and runs the full gate.

**Interfaces:**
- Consumes: `:require_admin` on_mount (existing) — redirects non-admins to `~p"/"`; `Cinder.AccountsFixtures.user_fixture/0`; `register_and_log_in_user` is available but here we log in a plain user explicitly to mirror `series_detail_live_test.exs`.
- Produces: nothing.

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/users_live_test.exs`:

```elixir
  test "a non-admin cannot reach /users", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
  end

  test "a logged-out visitor is redirected to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users")
  end
```

- [ ] **Step 2: Run it, expect FAIL or PASS-with-gap** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/users_live_test.exs'`. These should PASS immediately if the route is correctly gated (the existing `:admin`/`:require_authenticated` on_mount chain handles it). If the logged-out redirect target differs, adjust the expected `to:` to match `~p"/users/log-in"` per `user_auth.ex` `:require_authenticated`. (No production code change — this is a regression guard.)

- [ ] **Step 3: Implement** — none. If Step 2 surfaced a mismatch (e.g. redirect target), the fix is to correct the test expectation to the actual hook target; do NOT weaken the auth. Then run the FULL gate to confirm Phase 1 is green end-to-end:

```bash
pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test'
```

This runs compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Fix any credo/format/warning traps now (e.g. run `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix format'` and re-stage).

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test'` (full gate green).

- [ ] **Step 5: Commit** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && git add test/cinder_web/live/users_live_test.exs && git commit -m "test(users-live): non-admin and logged-out authorization coverage for /users"'`

---

# Phase 2 — Catalog R/U/D + cancel

Confirmed: no `list_grabs/0` exists yet (Phase 2 adds it), and no `remove` mock usage yet (Phase 0 adds the callback; Phase 2 is the first consumer in Catalog). I have full context. Writing the Phase 2 plan now.

### Task 1: `Catalog.update_movie/2` + `Catalog.update_series/2` (metadata edits)

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `update_movie/2` near `add_to_watchlist/1` ~line 53; add `update_series/2` and a private `Series.admin_changeset/2` call near `list_series/0` ~line 219); modify `lib/cinder/catalog/series.ex` (add `admin_changeset/2` after `refresh_changeset/2` ~line 75)
- Test: `test/cinder/catalog_admin_test.exs` (new file)

**Interfaces:**
- Consumes (Phase 0): nothing new here.
- Produces:
  - `Cinder.Catalog.update_movie(%Movie{}, attrs :: map()) :: {:ok, %Movie{}} | {:error, %Ecto.Changeset{}}` — reuses `Movie.changeset/2` (casts `:tmdb_id, :imdb_id, :title, :year, :poster_path`; NOT `:status`).
  - `Cinder.Catalog.update_series(%Series{}, attrs :: map()) :: {:ok, %Series{}} | {:error, %Ecto.Changeset{}}` — uses a new `Series.admin_changeset/2` that does NOT cast `monitor_strategy` (no cascade to seasons/episodes).
  - `Cinder.Catalog.Series.admin_changeset(series, attrs)` — casts `[:tvdb_id, :title, :year, :poster_path]`, validates `[:title]`. Excludes `monitor_strategy` and `monitored`.

- [ ] **Step 1: Write the failing test** — create `test/cinder/catalog_admin_test.exs`:
```elixir
defmodule Cinder.CatalogAdminTest do
  # async: false — sibling tasks in this file exercise Repo.transaction (cancel/delete);
  # the single-connection SQLite Sandbox needs shared mode for nested transactions.
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}

  defp movie!(attrs \\ %{}) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  describe "update_movie/2" do
    test "edits metadata via Movie.changeset, leaving status untouched" do
      movie = movie!(%{title: "Old", year: 2009})

      assert {:ok, %Movie{} = updated} =
               Catalog.update_movie(movie, %{title: "Inception", year: 2010})

      assert updated.title == "Inception"
      assert updated.year == 2010
      # status is not castable on Movie.changeset/2, so it stays put.
      assert updated.status == movie.status
      assert Repo.get!(Movie, movie.id).title == "Inception"
    end

    test "a status key in attrs is ignored (status stays in transition)" do
      movie = movie!()
      assert {:ok, updated} = Catalog.update_movie(movie, %{title: "X", status: :available})
      assert updated.status == :requested
    end

    test "returns {:error, changeset} on a blank required title" do
      movie = movie!()
      assert {:error, %Ecto.Changeset{}} = Catalog.update_movie(movie, %{title: ""})
    end
  end

  describe "update_series/2" do
    setup do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: true,
          monitor_strategy: :none
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1, monitored: true})
      {:ok, series: series, season: season}
    end

    test "edits descriptive fields", %{series: series} do
      assert {:ok, %Series{} = updated} =
               Catalog.update_series(series, %{title: "New Title", year: 2009})

      assert updated.title == "New Title"
      assert updated.year == 2009
      assert Repo.get!(Series, series.id).title == "New Title"
    end

    test "does NOT cascade monitor_strategy to existing seasons/episodes", %{
      series: series,
      season: season
    } do
      assert {:ok, updated} = Catalog.update_series(series, %{monitor_strategy: :all, title: "Z"})
      # monitor_strategy is not castable on admin_changeset → preserved.
      assert updated.monitor_strategy == :none
      # the request flow's per-season monitored: true is not clobbered.
      assert Repo.get!(Cinder.Catalog.Season, season.id).monitored == true
    end

    test "returns {:error, changeset} on a blank title", %{series: series} do
      assert {:error, %Ecto.Changeset{}} = Catalog.update_series(series, %{title: ""})
    end
  end
end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_admin_test.exs` → fails with `(UndefinedFunctionError) function Cinder.Catalog.update_movie/2 is undefined or private`.

- [ ] **Step 3: Implement** — in `lib/cinder/catalog/series.ex`, add after `refresh_changeset/2`:
```elixir
  @doc """
  Changeset for the admin metadata edit (`Catalog.update_series/2`). Casts only the
  descriptive fields — `monitor_strategy` and `monitored` are deliberately NOT castable so
  an admin title/year edit never cascades a strategy change onto existing seasons/episodes
  (the request flow sets `monitor_strategy: :none` while flipping per-season `monitored: true`;
  casting strategy here would clobber that — `refresh_changeset/2` excludes it for the same reason).
  """
  def admin_changeset(series, attrs) do
    series
    |> cast(attrs, [:tvdb_id, :title, :year, :poster_path])
    |> validate_required([:title])
  end
```
In `lib/cinder/catalog.ex`, add after `add_to_watchlist/1` (~line 53):
```elixir
  @doc """
  Admin metadata edit for a movie (title/year/poster/ids). Reuses `Movie.changeset/2`, which
  does NOT cast `:status` — status changes go through `transition/2` (the choke-point). Returns
  `{:ok, movie}` or `{:error, changeset}`.
  """
  def update_movie(%Movie{} = movie, attrs) do
    movie
    |> Movie.changeset(attrs)
    |> Repo.update()
  end
```
And add after `list_series/0` (~line 219):
```elixir
  @doc """
  Admin metadata edit for a series. Uses `Series.admin_changeset/2`, which excludes
  `monitor_strategy`/`monitored` so the edit never cascades a strategy change to existing
  seasons/episodes. Per-season/episode monitoring stays on `set_season_monitored/2` /
  `set_episode_monitored/2`. Returns `{:ok, series}` or `{:error, changeset}`.
  """
  def update_series(%Series{} = series, attrs) do
    series
    |> Series.admin_changeset(attrs)
    |> Repo.update()
  end
```

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_admin_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder/catalog.ex lib/cinder/catalog/series.ex test/cinder/catalog_admin_test.exs
git commit -m "catalog: admin update_movie/2 + update_series/2 (no monitor_strategy cascade)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 2: `Catalog.cancel_movie/2` (guard, client-remove, transition to `:cancelled`) + `delete_movie/2`

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `@cancellable_movie_statuses` + `cancellable?/1` consumed-from-Phase-0 note below; add `cancel_movie/2` and `delete_movie/2` near `retry_movie/1` ~line 112; add `broadcast_movie_deleted/1` per Phase 0 contract — see note)
- Test: `test/cinder/catalog_admin_test.exs` (append `cancel_movie/2` + `delete_movie/2` describes)

**Interfaces:**
- Consumes (Phase 0, verbatim — do NOT redefine these; they already exist on the branch after Phase 0 merges):
  - `Cinder.Catalog.cancellable?(%Movie{}) :: boolean` and `@cancellable_movie_statuses = [:requested, :searching, :downloading, :downloaded]`.
  - `Cinder.Catalog.transition(%Movie{}, %{status: :cancelled}) :: {:ok, %Movie{}} | {:error, cs}` (choke-point; does NOT validate the transition).
  - `Cinder.Download.client_for(protocol) :: {:ok, module} | :error` (nil protocol → `:torrent`).
  - `@callback Cinder.Download.Client.remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}` (idempotent; `opts` carries `delete_files:` default `true`).
  - `Cinder.Catalog.broadcast_movie_deleted(id) :: :ok` → emits `{:movie_deleted, id}` on `"movies"`.
  - Mox: `Cinder.Download.ClientMock` (torrent), `Cinder.Download.SabnzbdClientMock` (usenet), both `for: Cinder.Download.Client`.
- Produces:
  - `Cinder.Catalog.cancel_movie(%Movie{}, actor) :: {:ok, %Movie{}} | {:error, :not_cancellable} | {:error, term()}` — guards `cancellable?/1`; removes the client download if `download_id` present (outside txn); transitions to `:cancelled`. `actor` is `%Cinder.Accounts.User{} | nil` (passed to `Audit.log/4`).
  - `Cinder.Catalog.delete_movie(%Movie{}, actor) :: {:ok, %Movie{}} | {:error, term()}` — cancels-the-client-download-first for an active row with a non-nil `download_id`, then `Repo.delete`; broadcasts `{:movie_deleted, id}`.

> NOTE on Phase 0 vs Phase 2 ownership: `@cancellable_movie_statuses`, `cancellable?/1`, the `:cancelled` enum value, `status_badge_class(:cancelled)`, `Download.Client.remove/2` (+ qBit/SAB impls), and `broadcast_movie_deleted/1` are ALL produced by Phase 0 and assumed present. If a grep on the branch shows any of them missing, STOP — Phase 0 has not merged; do not re-create them here.

> NOTE on audit: `Audit.log/4` does NOT open a transaction; the caller must call it inside its own `Repo.transaction`, after the guard, before commit. For `cancel_movie/2`, client I/O (`Client.remove/2`) stays OUTSIDE the transaction (external-I/O rule). The structure is: guard → `Client.remove/2` (if download_id) → `Repo.transaction(fn -> transition + Audit.log end)`. Because `transition/2` itself calls `Repo.update` + broadcast, and we also want the audit row in the same txn, wrap the `Movie.transition_changeset` update + `Audit.log` directly, then broadcast after commit. See implementation.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/catalog_admin_test.exs` (add `import Mox`, `alias Cinder.Audit.AdminAudit`, and `setup :verify_on_exit!` near the top of the new describes; add `alias Cinder.AccountsFixtures` usage):
```elixir
  describe "cancel_movie/2" do
    setup :verify_on_exit!

    test "an active movie with a download is cancelled and the client download removed" do
      import Mox
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie!()
        |> then(&elem(Catalog.transition(&1, %{
          status: :downloading,
          download_id: "HASH-1",
          download_protocol: :torrent
        }), 1))

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-1", opts ->
        assert Keyword.fetch!(opts, :delete_files) == true
        :ok
      end)

      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :cancelled
    end

    test "a requested movie with no download is cancelled without touching the client" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!()
      # No expect/0 on the client → if cancel_movie called it, verify_on_exit! would fail.
      assert {:ok, %Movie{status: :cancelled}} = Catalog.cancel_movie(movie, actor)
    end

    test "a non-cancellable (terminal/available) movie returns {:error, :not_cancellable}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      assert {:error, :not_cancellable} = Catalog.cancel_movie(movie, actor)
      assert Repo.get!(Movie, movie.id).status == :available
    end

    test "writes an admin_audit row for the cancel (in-txn)" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!()
      assert {:ok, _} = Catalog.cancel_movie(movie, actor)

      audit = Repo.one!(Cinder.Audit.AdminAudit)
      assert audit.action == "cancel_movie"
      assert audit.entity_type == "Movie"
      assert audit.entity_id == movie.id
      assert audit.actor_id == actor.id
    end
  end

  describe "delete_movie/2" do
    setup :verify_on_exit!

    test "deletes an idle movie and broadcasts {:movie_deleted, id}" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))
      id = movie.id
      Catalog.subscribe()

      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert_receive {:movie_deleted, ^id}
      assert Repo.get(Movie, id) == nil
    end

    test "an active movie with a download is cancelled (client-removed) before delete" do
      import Mox
      actor = Cinder.AccountsFixtures.admin_fixture()

      movie =
        movie!()
        |> then(&elem(Catalog.transition(&1, %{
          status: :downloading,
          download_id: "HASH-2",
          download_protocol: :usenet
        }), 1))

      # usenet → SabnzbdClientMock.
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "HASH-2", _opts -> :ok end)

      id = movie.id
      assert {:ok, %Movie{}} = Catalog.delete_movie(movie, actor)
      assert Repo.get(Movie, id) == nil
    end

    test "writes an admin_audit row for the delete" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      movie = movie!()
      assert {:ok, _} = Catalog.delete_movie(movie, actor)
      assert Repo.one!(Cinder.Audit.AdminAudit).action == "delete_movie"
    end
  end
```
> Note: this describe block exercises `transition/2`/`Repo.transaction`; the file is already `use Cinder.DataCase, async: false` (Task 1) and these new describes add `setup :verify_on_exit!`. Mox is in-process (no poller), so `:verify_on_exit!` is correct, not `:set_mox_global`.

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_admin_test.exs:<cancel_movie describe line>` → `(UndefinedFunctionError) function Cinder.Catalog.cancel_movie/2 is undefined or private`.

- [ ] **Step 3: Implement** — in `lib/cinder/catalog.ex` add `alias Cinder.Audit` to the existing alias block (top of module, after `alias Cinder.Repo`), and add after `retry_movie(%Movie{})` (~line 112):
```elixir
  @doc """
  Cancels an in-flight movie: removes the orphaned client download (if any) and transitions
  it to `:cancelled`. Guards `cancellable?/1` server-side (`transition/2` does not validate the
  transition). Returns `{:error, :not_cancellable}` for a terminal/available/parked movie.

  Client I/O runs OUTSIDE the DB transaction (external-I/O rule). The `:cancelled` transition +
  the audit row are written in one transaction so a rolled-back cancel leaves no orphan audit row;
  the `{:movie_updated, _}` broadcast (via the transition) fires after commit.
  """
  def cancel_movie(%Movie{} = movie, actor) do
    if cancellable?(movie) do
      with :ok <- remove_movie_download(movie) do
        result =
          Repo.transaction(fn ->
            case movie |> Movie.transition_changeset(%{status: :cancelled}) |> Repo.update() do
              {:ok, updated} ->
                {:ok, _} = Audit.log(actor, :cancel_movie, updated, %{from: movie.status})
                updated

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)

        with {:ok, updated} <- result do
          broadcast({:movie_updated, updated})
          {:ok, updated}
        end
      end
    else
      {:error, :not_cancellable}
    end
  end

  @doc """
  Deletes a movie's DB row. An active row with a tracked download is cancelled first (which
  removes the client download) so delete never orphans a live download. Broadcasts
  `{:movie_deleted, id}` on the `"movies"` topic. On-disk library files are intentionally left
  for the deferred unlink feature. The delete + audit row are written in one transaction.
  """
  def delete_movie(%Movie{} = movie, actor) do
    with :ok <- maybe_cancel_download_for_delete(movie) do
      result =
        Repo.transaction(fn ->
          case Repo.delete(movie) do
            {:ok, deleted} ->
              {:ok, _} = Audit.log(actor, :delete_movie, deleted, %{title: deleted.title})
              deleted

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      with {:ok, deleted} <- result do
        broadcast_movie_deleted(deleted.id)
        {:ok, deleted}
      end
    end
  end

  # Remove the tracked client download if present; skip entirely when download_id is nil.
  # client_for/1 maps a nil protocol to :torrent; an unconfigured protocol (:error) is treated
  # as "nothing to remove" so a cancel/delete is never blocked by client resolution.
  defp remove_movie_download(%Movie{download_id: nil}), do: :ok

  defp remove_movie_download(%Movie{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> client.remove(id, delete_files: true)
      :error -> :ok
    end
  end

  # For delete: only an active (cancellable) row with a tracked download needs the client removed.
  # A terminal/available row keeps its (already-imported or absent) download untouched.
  defp maybe_cancel_download_for_delete(%Movie{download_id: nil}), do: :ok

  defp maybe_cancel_download_for_delete(%Movie{} = movie) do
    if cancellable?(movie), do: remove_movie_download(movie), else: :ok
  end
```
Add `alias Cinder.Download` to the alias block too (top of module). `broadcast_movie_deleted/1`, `cancellable?/1`, `@cancellable_movie_statuses` are Phase 0 — already present.

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_admin_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "catalog: cancel_movie/2 + delete_movie/2 (client-remove, audit, broadcast)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 3: `Catalog.cancel_series/2` + `delete_series/2` (grab reaping, unmonitor, broadcasts)

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `cancel_series/2`, `delete_series/2`, and a private `grabs_for_series/1` helper near `delete_grab/1` ~line 458; add `list_grabs/0` near `list_grabs_downloaded/0` ~line 555)
- Test: `test/cinder/catalog_admin_test.exs` (append `cancel_series/2` + `delete_series/2` describes)

**Interfaces:**
- Consumes (Phase 0 + existing):
  - `Cinder.Catalog.delete_grab(%Grab{}) :: {:ok, %Grab{}} | …` (existing; nilifies episode `grab_id`, broadcasts `{:series_updated, _}`).
  - `Cinder.Catalog.set_season_monitored(%Season{}, false)` / `set_episode_monitored(%Episode{}, false)` (existing).
  - `Cinder.Download.client_for/1`, `Client.remove/2` (Phase 0).
  - `Cinder.Catalog.broadcast_series_deleted(id) :: :ok` → `{:series_deleted, id}` on `"series"` (Phase 0).
  - `Audit.log/4` (Phase 0).
  - FK cascade (Phase 0): `delete_series` relies on `seasons/episodes :delete_all` and `episodes.grab_id :nilify_all` — so grabs MUST be reaped BEFORE `Repo.delete(series)`.
- Produces:
  - `Cinder.Catalog.cancel_series(%Series{}, actor) :: {:ok, %Series{}} | {:error, term()}` — reaps ALL grabs (any state incl `:downloaded`) via the episode join, `Client.remove/2` (if `download_id`) + `delete_grab/1` each; sets every season+episode `monitored: false`; broadcasts `{:series_updated, id}`; audits.
  - `Cinder.Catalog.delete_series(%Series{}, actor) :: {:ok, %Series{}} | {:error, term()}` — reaps grabs FIRST, then `Repo.delete(series)` (seasons/episodes cascade); broadcasts `{:series_deleted, id}`; audits.
  - `Cinder.Catalog.list_grabs() :: [%Grab{}]` — all grabs ordered newest-first, preloaded `episode → season → series` (note: `Grab has_many :episodes`, so preload is `[episodes: [season: :series]]`).
  - Private `grabs_for_series(series_id) :: [%Grab{}]`.

- [ ] **Step 1: Write the failing test** — append to `test/cinder/catalog_admin_test.exs`. Add a `series_with_grabs` helper inside this describe-block area (mirrors `catalog_tv_pipeline_test.exs`):
```elixir
  describe "cancel_series/2 and delete_series/2" do
    setup :verify_on_exit!
    import Mox

    alias Cinder.Catalog.{Episode, Grab, Season, Series}

    defp series_tree do
      series =
        Repo.insert!(%Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: true,
          monitor_strategy: :all
        })

      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

      ep =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          air_date: ~D[2001-01-01]
        })

      {series, season, ep}
    end

    test "cancel_series reaps all grabs (incl :downloaded), removes downloads, unmonitors" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()

      # A downloading grab and a downloaded (content_path set) grab — both must be reaped.
      {:ok, dl} = Catalog.create_grab("HASH-A", :torrent, [ep.id])

      ep2 =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 2,
          monitored: true,
          air_date: ~D[2001-01-08]
        })

      {:ok, done} = Catalog.create_grab("HASH-B", :usenet, [ep2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(done, "/downloads/pack")

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-A", _opts -> :ok end)
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "HASH-B", _opts -> :ok end)

      sid = series.id
      Catalog.subscribe_series()

      assert {:ok, %Series{}} = Catalog.cancel_series(series, actor)
      assert_receive {:series_updated, ^sid}

      # Both grabs gone.
      assert Repo.all(Grab) == []
      # Season + episodes unmonitored so wanted_episodes won't re-grab.
      assert Repo.get!(Season, season.id).monitored == false
      assert Repo.get!(Episode, ep.id).monitored == false
      assert Repo.get!(Episode, ep2.id).monitored == false
      # The series itself survives a cancel.
      assert Repo.get(Series, sid)
    end

    test "cancel_series stops re-grab: wanted_episodes returns nothing afterward" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      # Before: the aired, monitored, file-less, grab-less episode is wanted.
      assert series.id in Enum.map(Catalog.wanted_episodes(), & &1.season.series_id)

      assert {:ok, _} = Catalog.cancel_series(series, actor)
      refute series.id in Enum.map(Catalog.wanted_episodes(), & &1.season.series_id)
    end

    test "cancel_series writes an admin_audit row" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      assert {:ok, _} = Catalog.cancel_series(series, actor)
      audit = Repo.one!(Cinder.Audit.AdminAudit)
      assert audit.action == "cancel_series"
      assert audit.entity_type == "Series"
      assert audit.entity_id == series.id
    end

    test "delete_series reaps grabs first, then cascades seasons/episodes, broadcasts deleted" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, season, ep} = series_tree()
      {:ok, _grab} = Catalog.create_grab("HASH-C", :torrent, [ep.id])

      expect(Cinder.Download.ClientMock, :remove, fn "HASH-C", _opts -> :ok end)

      sid = series.id
      Catalog.subscribe_series()

      assert {:ok, %Series{}} = Catalog.delete_series(series, actor)
      assert_receive {:series_deleted, ^sid}

      assert Repo.get(Series, sid) == nil
      assert Repo.get(Season, season.id) == nil
      assert Repo.get(Episode, ep.id) == nil
      assert Repo.all(Grab) == []
    end

    test "delete_series writes an admin_audit row" do
      actor = Cinder.AccountsFixtures.admin_fixture()
      {series, _season, _ep} = series_tree()
      assert {:ok, _} = Catalog.delete_series(series, actor)
      assert Repo.one!(Cinder.Audit.AdminAudit).action == "delete_series"
    end
  end

  describe "list_grabs/0" do
    test "lists all grabs newest-first with episode→season→series preloaded" do
      series =
        Repo.insert!(%Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "S",
          monitored: true,
          monitor_strategy: :all
        })

      season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

      ep =
        Repo.insert!(%Cinder.Catalog.Episode{
          season_id: season.id,
          episode_number: 1,
          air_date: ~D[2001-01-01]
        })

      {:ok, _} = Catalog.create_grab("H1", :torrent, [ep.id])

      assert [grab] = Catalog.list_grabs()
      assert [loaded_ep] = grab.episodes
      assert loaded_ep.season.series.id == series.id
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder/catalog_admin_test.exs` → `(UndefinedFunctionError) function Cinder.Catalog.cancel_series/2 is undefined or private`.

- [ ] **Step 3: Implement** — in `lib/cinder/catalog.ex`, add after `delete_grab/1` (~line 458):
```elixir
  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import — a surviving downloaded grab would re-import next tick),
  removing each tracked client download, then unmonitors every season and episode so the TV
  poller's `wanted_episodes` does not re-grab. Broadcasts `{:series_updated, id}`. Audited.
  Client I/O runs outside the DB transaction.
  """
  def cancel_series(%Series{} = series, actor) do
    reap_series_grabs(series.id)
    unmonitor_series_tree(series.id)

    {:ok, _} =
      Repo.transaction(fn ->
        Audit.log(actor, :cancel_series, series, %{title: series.title})
      end)

    broadcast_series(series.id)
    {:ok, series}
  end

  @doc """
  Deletes a series and its tree. Grabs are reaped FIRST (the `episode.grab_id` FK nilifies on the
  episode cascade, so after `Repo.delete(series)` the grabs would be unreachable for client removal
  and orphan their downloads). Each grab's tracked client download is removed (outside the txn),
  then `delete_grab/1`; then `Repo.delete(series)` cascades seasons/episodes at the DB. Broadcasts
  `{:series_deleted, id}`. Audited. On-disk library files are intentionally left for the deferred
  unlink feature.
  """
  def delete_series(%Series{} = series, actor) do
    reap_series_grabs(series.id)

    result =
      Repo.transaction(fn ->
        case Repo.delete(series) do
          {:ok, deleted} ->
            {:ok, _} = Audit.log(actor, :delete_series, deleted, %{title: deleted.title})
            deleted

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, deleted} <- result do
      broadcast_series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  # Remove every grab serving the series: client-remove the tracked download (if any), then
  # delete_grab/1. Used by BOTH cancel_series and delete_series (same all-states collection).
  defp reap_series_grabs(series_id) do
    for grab <- grabs_for_series(series_id) do
      remove_grab_download(grab)
      delete_grab(grab)
    end

    :ok
  end

  defp remove_grab_download(%Grab{download_id: nil}), do: :ok

  defp remove_grab_download(%Grab{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> client.remove(id, delete_files: true)
      :error -> :ok
    end
  end

  # Grabs whose episodes belong to this series (via the episode→season join), ALL states.
  defp grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: e in Episode,
        on: e.grab_id == g.id,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        distinct: true
    )
  end

  # Unmonitor every season + episode of the series in one write each so wanted_episodes is empty.
  defp unmonitor_series_tree(series_id) do
    ts = now()

    Repo.update_all(from(s in Season, where: s.series_id == ^series_id),
      set: [monitored: false, updated_at: ts]
    )

    Repo.update_all(
      from(e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id
      ),
      set: [monitored: false, updated_at: ts]
    )

    :ok
  end
```
Add `list_grabs/0` after `list_grabs_downloaded/0` (~line 555):
```elixir
  @doc "All grabs newest-first, with `episodes: [season: :series]` preloaded for the admin /grabs view."
  def list_grabs do
    Repo.all(from g in Grab, order_by: [desc: g.id], preload: [episodes: [season: :series]])
  end
```

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder/catalog_admin_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "catalog: cancel_series/2 + delete_series/2 (grab reaping order, unmonitor) + list_grabs/0

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 4: `:cancelled` badge renders without crashing (regression guard)

**Files:**
- Test: `test/cinder_web/components/status_badge_test.exs` (new file)

**Interfaces:**
- Consumes (Phase 0): `CinderWeb.CoreComponents.movie_status_badge/1` with `status_badge_class(:cancelled) => "badge-error"` (added in Phase 0). This task is a PHASE-2-OWNED regression test confirming a `:cancelled` movie row renders end-to-end (the spec calls for a LiveView render of a cancelled badge; this is the component-level proof, complemented by the MoviesLive test in Task 5).
- Produces: nothing (test-only).

- [ ] **Step 1: Write the failing test** — create `test/cinder_web/components/status_badge_test.exs`:
```elixir
defmodule CinderWeb.StatusBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.CoreComponents

  test "renders a :cancelled movie status badge without raising (badge-error)" do
    html = render_component(&CoreComponents.movie_status_badge/1, %{status: :cancelled})
    assert html =~ "badge-error"
    assert html =~ "cancelled"
  end

  test "renders every movie status without raising FunctionClauseError" do
    for status <- [
          :requested,
          :searching,
          :downloading,
          :downloaded,
          :available,
          :no_match,
          :search_failed,
          :import_failed,
          :cancelled
        ] do
      assert render_component(&CoreComponents.movie_status_badge/1, %{status: status}) =~ "badge"
    end
  end
end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/components/status_badge_test.exs`. If Phase 0 merged, this PASSES immediately (it is a regression net). If `status_badge_class(:cancelled)` is missing it fails with `(FunctionClauseError) no function clause matching … status_badge_class(:cancelled)` — that means Phase 0 did not land; STOP and resolve Phase 0 before continuing.

- [ ] **Step 3: Implement** — none in this task (Phase 0 owns the clause). This task only adds the guard test. If you reached here because the test failed for a NON-Phase-0 reason, fix the test, not the component.

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/components/status_badge_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add test/cinder_web/components/status_badge_test.exs
git commit -m "test: :cancelled movie status badge renders without crashing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 5: `MoviesLive` (`/movies`) — list, edit, cancel, delete with in-LiveView confirm

**Files:**
- Create: `lib/cinder_web/live/movies_live.ex`
- Modify: `lib/cinder_web/router.ex` (add `live "/movies", MoviesLive` to the `:admin` `live_session`, ~line 71 after `live "/users", UsersLive`)
- Test: `test/cinder_web/live/movies_live_test.exs` (new)

**Interfaces:**
- Consumes: `Catalog.list_watchlist/0` (existing), `Catalog.get_movie_by_id/1` (existing), `Catalog.update_movie/2` (Task 1), `Catalog.cancel_movie/2` (Task 2), `Catalog.delete_movie/2` (Task 2), `Catalog.cancellable?/1` (Phase 0), `Catalog.subscribe/0` (existing), `{:movie_updated, movie}` / `{:movie_created, movie}` / `{:movie_deleted, id}` messages. `CoreComponents.movie_status_badge/1`, `<.header>`, `<.input>`. `socket.assigns.current_scope.user` (the server-side actor for audit).
- Produces: route `/movies` (`:admin`).

- [ ] **Step 1: Write the failing test** — create `test/cinder_web/live/movies_live_test.exs`:
```elixir
defmodule CinderWeb.MoviesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.Movie

  setup :register_and_log_in_admin
  setup :set_mox_global

  defp movie!(attrs \\ %{}) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  test "lists movies with their status", %{conn: conn} do
    movie!(%{title: "Arrival", year: 2016})
    {:ok, _lv, html} = live(conn, ~p"/movies")
    assert html =~ "Arrival"
    assert html =~ "requested"
  end

  test "editing a movie's metadata persists", %{conn: conn} do
    movie = movie!(%{title: "Old"})
    {:ok, lv, _html} = live(conn, ~p"/movies")

    lv |> element(~s|button[phx-click="edit"][phx-value-id="#{movie.id}"]|) |> render_click()
    lv |> form("#movie-form-#{movie.id}", %{"movie" => %{"title" => "New", "year" => "2020"}}) |> render_submit()

    assert Repo.get!(Movie, movie.id).title == "New"
  end

  test "cancelling an active movie removes the client download and sets :cancelled", %{conn: conn} do
    {:ok, movie} =
      Catalog.transition(movie!(), %{status: :downloading, download_id: "H", download_protocol: :torrent})

    expect(Cinder.Download.ClientMock, :remove, fn "H", _opts -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/movies")
    lv |> element(~s|button[phx-click="ask_cancel"][phx-value-id="#{movie.id}"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_cancel"][phx-value-id="#{movie.id}"]|) |> render_click()

    assert Repo.get!(Movie, movie.id).status == :cancelled
  end

  test "deleting an idle movie drops it from the list", %{conn: conn} do
    movie = movie!() |> then(&elem(Catalog.transition(&1, %{status: :available}), 1))

    {:ok, lv, _html} = live(conn, ~p"/movies")
    lv |> element(~s|button[phx-click="ask_delete"][phx-value-id="#{movie.id}"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{movie.id}"]|) |> render_click()

    assert Repo.get(Movie, movie.id) == nil
    refute render(lv) =~ "movie-#{movie.id}"
  end

  test "a cancelled movie's badge renders (no crash)", %{conn: conn} do
    {:ok, _} = Catalog.transition(movie!(%{title: "Doomed"}), %{status: :cancelled})
    {:ok, _lv, html} = live(conn, ~p"/movies")
    assert html =~ "Doomed"
    assert html =~ "cancelled"
  end

  test "a non-admin is redirected away from /movies", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/movies")
  end
end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/movies_live_test.exs` → fails at `live(conn, ~p"/movies")` with a no-route / verified-route compile error (the route + module don't exist yet).

- [ ] **Step 3: Implement** — add the route in `lib/cinder_web/router.ex` inside `live_session :admin` (after `live "/users", UsersLive`):
```elixir
      live "/movies", MoviesLive
```
Create `lib/cinder_web/live/movies_live.ex`:
```elixir
defmodule CinderWeb.MoviesLive do
  @moduledoc """
  Admin movie management at `/movies`: list every watchlisted movie with its pipeline status,
  edit metadata, and cancel (active → `:cancelled` + client-remove) or delete (DB row) with an
  in-LiveView confirm step (mirrors RequestsLive's `denying` pattern — no data-confirm/JS). The
  active-set predicate (`Catalog.cancellable?/1`) drives whether the row offers Cancel vs Delete.
  Admin-gated by the `:admin` live_session. Subscribes to the `"movies"` topic so create/update/
  delete events keep an open list live.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       editing: nil,
       confirming: nil,
       form: nil
     )}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        form = to_form(Movie.changeset(movie, %{}))
        {:noreply, assign(socket, editing: movie.id, confirming: nil, form: form)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("save", %{"id" => id, "movie" => attrs}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        case Catalog.update_movie(movie, attrs) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(editing: nil, form: nil, movies: Catalog.list_watchlist())
             |> put_flash(:info, "Movie updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("ask_cancel", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:cancel, id}, editing: nil)}
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:delete, id}, editing: nil)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_cancel", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find(socket, id),
         {:ok, _} <- Catalog.cancel_movie(movie, actor) do
      {:noreply,
       socket
       |> assign(confirming: nil, movies: Catalog.list_watchlist())
       |> put_flash(:info, "Movie cancelled.")}
    else
      {:error, :not_cancellable} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "That movie can't be cancelled.")}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't cancel that movie.")}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find(socket, id),
         {:ok, _} <- Catalog.delete_movie(movie, actor) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Movie deleted.")}
    else
      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete that movie.")}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}
  end

  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find(socket, id) do
    Enum.find(socket.assigns.movies, &(to_string(&1.id) == to_string(id)))
  end

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Movies<:subtitle>Edit, cancel, or delete watchlisted movies.</:subtitle>
      </.header>

      <p :if={@movies == []} class="text-base-content/60">No movies yet.</p>

      <ul class="space-y-3">
        <li :for={m <- @movies} id={"movie-#{m.id}"} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{m.title}</span>
            <span :if={m.year} class="text-base-content/60">({m.year})</span>
            <.movie_status_badge status={m.status} />

            <div class="ml-auto flex gap-2">
              <button type="button" class="btn btn-xs" phx-click="edit" phx-value-id={m.id}>
                Edit
              </button>
              <button
                :if={Catalog.cancellable?(m)}
                type="button"
                class="btn btn-xs btn-warning"
                phx-click="ask_cancel"
                phx-value-id={m.id}
              >
                Cancel
              </button>
              <button
                :if={not Catalog.cancellable?(m)}
                type="button"
                class="btn btn-xs btn-error"
                phx-click="ask_delete"
                phx-value-id={m.id}
              >
                Delete
              </button>
            </div>
          </div>

          <.form
            :if={@editing == m.id}
            for={@form}
            id={"movie-form-#{m.id}"}
            phx-submit="save"
            phx-value-id={m.id}
            class="mt-3 flex flex-wrap items-end gap-2"
          >
            <.input field={@form[:title]} type="text" label="Title" />
            <.input field={@form[:year]} type="number" label="Year" />
            <button class="btn btn-sm btn-primary" type="submit">Save</button>
            <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit">Cancel</button>
          </.form>

          <div :if={@confirming == {:cancel, to_string(m.id)}} class="mt-3 flex items-center gap-2">
            <span class="text-sm">Cancel this movie and remove its download?</span>
            <button class="btn btn-sm btn-warning" phx-click="confirm_cancel" phx-value-id={m.id}>
              Confirm cancel
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
          </div>

          <div :if={@confirming == {:delete, to_string(m.id)}} class="mt-3 flex items-center gap-2">
            <span class="text-sm">Delete this movie's record? (Library files are left on disk.)</span>
            <button class="btn btn-sm btn-error" phx-click="confirm_delete" phx-value-id={m.id}>
              Confirm delete
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
```
> Note: `confirming` is stored as `{:cancel | :delete, id_string}` — the render compares `{:cancel, to_string(m.id)}` because `phx-value-id` arrives as a string. Set it as a string in the `ask_*` handlers by leaving the param as-is (`phx-value-id={m.id}` sends a string).

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/live/movies_live_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder_web/live/movies_live.ex lib/cinder_web/router.ex test/cinder_web/live/movies_live_test.exs
git commit -m "web: MoviesLive (/movies) — list/edit/cancel/delete with in-LV confirm

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 6: `GrabsLive` (`/grabs`) — list newest-first with derived series/episode + delete

**Files:**
- Create: `lib/cinder_web/live/grabs_live.ex`
- Modify: `lib/cinder_web/router.ex` (add `live "/grabs", GrabsLive` to `:admin`, after `live "/movies", MoviesLive`)
- Test: `test/cinder_web/live/grabs_live_test.exs` (new)

**Interfaces:**
- Consumes: `Catalog.list_grabs/0` (Task 3), `Catalog.delete_grab/1` (existing — note: `delete_grab/1` is NOT audited; the spec lists Grabs as R/D and `delete_grab/1` is the existing un-audited writer. The /grabs delete uses it directly — audit of grab deletion is out of Phase-2 scope per the contract, which only names `delete_grab/1` already exists). `Catalog.subscribe_series/0`, `{:series_updated, _}`. `<.header>`.
- Produces: route `/grabs` (`:admin`).

- [ ] **Step 1: Write the failing test** — create `test/cinder_web/live/grabs_live_test.exs`:
```elixir
defmodule CinderWeb.GrabsLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.{Episode, Grab, Season, Series}

  setup :register_and_log_in_admin

  defp grab! do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Breaking Bad",
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1})

    ep =
      Repo.insert!(%Episode{
        season_id: season.id,
        episode_number: 7,
        title: "Pilot",
        air_date: ~D[2008-01-20]
      })

    {:ok, grab} = Catalog.create_grab("HASH-#{System.unique_integer([:positive])}", :torrent, [ep.id])
    {grab, series}
  end

  test "lists grabs with their derived series", %{conn: conn} do
    {_grab, _series} = grab!()
    {:ok, _lv, html} = live(conn, ~p"/grabs")
    assert html =~ "Breaking Bad"
  end

  test "deleting a grab removes it", %{conn: conn} do
    {grab, _series} = grab!()
    {:ok, lv, _html} = live(conn, ~p"/grabs")

    lv |> element(~s|button[phx-click="ask_delete"][phx-value-id="#{grab.id}"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{grab.id}"]|) |> render_click()

    assert Repo.get(Grab, grab.id) == nil
    refute render(lv) =~ "grab-#{grab.id}"
  end

  test "a non-admin is redirected away from /grabs", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/grabs")
  end
end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/grabs_live_test.exs` → fails at `~p"/grabs"` (no route / no module).

- [ ] **Step 3: Implement** — add the route in `lib/cinder_web/router.ex` (inside `:admin`, after `live "/movies", MoviesLive`):
```elixir
      live "/grabs", GrabsLive
```
Create `lib/cinder_web/live/grabs_live.ex`:
```elixir
defmodule CinderWeb.GrabsLive do
  @moduledoc """
  Admin grab list at `/grabs`: every in-flight download newest-first, with its derived series and
  episodes and a download-vs-downloaded status, plus an in-LiveView delete confirm. Grabs are
  created by the pipeline only (no create path). Admin-gated by the `:admin` live_session.
  Subscribes to the `"series"` topic so a grab created/finished elsewhere keeps the list live.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe_series()
    {:ok, assign(socket, grabs: Catalog.list_grabs(), confirming: nil)}
  end

  @impl true
  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: id)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    grab = Enum.find(socket.assigns.grabs, &(to_string(&1.id) == id))

    if grab, do: Catalog.delete_grab(grab)

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(:info, "Grab deleted.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:series_updated, _id}, socket) do
    {:noreply, assign(socket, grabs: Catalog.list_grabs())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_grab), do: "—"

  defp grab_state(%{content_path: nil}), do: "downloading"
  defp grab_state(_grab), do: "downloaded"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Grabs<:subtitle>In-flight downloads, newest first.</:subtitle>
      </.header>

      <p :if={@grabs == []} class="text-base-content/60">No grabs.</p>

      <ul class="space-y-3">
        <li :for={g <- @grabs} id={"grab-#{g.id}"} class="card bg-base-200 p-4">
          <div class="flex items-center gap-3">
            <span class="font-semibold">{series_title(g)}</span>
            <span class="badge badge-sm">{grab_state(g)}</span>
            <span class="text-sm text-base-content/60">{g.download_protocol}</span>
            <span class="text-xs text-base-content/50">{g.download_id}</span>

            <button
              type="button"
              class="btn btn-xs btn-error ml-auto"
              phx-click="ask_delete"
              phx-value-id={g.id}
            >
              Delete
            </button>
          </div>

          <div :if={@confirming == to_string(g.id)} class="mt-3 flex items-center gap-2">
            <span class="text-sm">Delete this grab? Its episodes are unlinked.</span>
            <button class="btn btn-sm btn-error" phx-click="confirm_delete" phx-value-id={g.id}>
              Confirm delete
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/live/grabs_live_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder_web/live/grabs_live.ex lib/cinder_web/router.ex test/cinder_web/live/grabs_live_test.exs
git commit -m "web: GrabsLive (/grabs) — list newest-first + delete with confirm

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 7: `SeriesDetailLive` — admin edit / cancel / delete controls (+ `{:series_deleted}` handling)

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex` (add `Catalog.subscribe_series` already present; extend `handle_event/3` with edit/cancel/delete + confirm; add `{:series_deleted, id}` `handle_info`; add controls to `render/1`)
- Test: `test/cinder_web/live/series_detail_live_test.exs` (append admin edit/cancel/delete tests)

**Interfaces:**
- Consumes: `Catalog.update_series/2` (Task 1), `Catalog.cancel_series/2` (Task 3), `Catalog.delete_series/2` (Task 3), `Catalog.get_series_with_tree/1` (existing), `Series.admin_changeset/2` (Task 1) via `update_series`, `{:series_deleted, id}` (Phase 0). `socket.assigns.current_scope.user`.
- Produces: nothing new (extends existing route).

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/series_detail_live_test.exs` (the file is already `use CinderWeb.ConnCase, async: false`, `setup :register_and_log_in_admin`, `setup :set_mox_global`, and has the `create_series/1` helper):
```elixir
  test "admin edits the series title", %{conn: conn} do
    series = create_series(710)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv |> element(~s|button[phx-click="edit_series"]|) |> render_click()
    lv |> form("#series-form", %{"series" => %{"title" => "Renamed", "year" => "2021"}}) |> render_submit()

    assert Repo.get!(Cinder.Catalog.Series, series.id).title == "Renamed"
  end

  test "admin cancels the series: grabs reaped, episodes unmonitored", %{conn: conn} do
    series = create_series(711)
    ep = first_episode(series.id)
    # Monitor it + give it an active grab.
    {:ok, _} = Catalog.set_episode_monitored(ep, true)
    {:ok, _grab} = Catalog.create_grab("H-711", :torrent, [ep.id])

    expect(Cinder.Download.ClientMock, :remove, fn "H-711", _opts -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
    lv |> element(~s|button[phx-click="ask_cancel_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_cancel_series"]|) |> render_click()

    assert Repo.all(Cinder.Catalog.Grab) == []
    assert Repo.reload(ep).monitored == false
  end

  test "admin deletes the series and is redirected to /series", %{conn: conn} do
    series = create_series(712)
    {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")

    lv |> element(~s|button[phx-click="ask_delete_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete_series"]|) |> render_click()

    assert Repo.get(Cinder.Catalog.Series, series.id) == nil
    assert_redirect(lv, "/series")
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/series_detail_live_test.exs:<admin edits line>` → fails: the `edit_series` button isn't rendered, so `element/2` raises "no element found".

- [ ] **Step 3: Implement** — edit `lib/cinder_web/live/series_detail_live.ex`. Add `alias Cinder.Catalog.Series` to the existing `alias Cinder.Catalog.{Episode, Season}` (make it `{Episode, Season, Series}`). In `mount/3`, extend the assign to seed the confirm/edit state:
```elixir
      {:ok, assign(socket, series: series, editing?: false, confirming: nil, form: nil)}
```
Add these `handle_event/3` clauses BEFORE the existing catch-all `def handle_event(_event, _params, socket)`:
```elixir
  def handle_event("edit_series", _params, socket) do
    form = to_form(Series.admin_changeset(socket.assigns.series, %{}))
    {:noreply, assign(socket, editing?: true, confirming: nil, form: form)}
  end

  def handle_event("cancel_edit_series", _params, socket) do
    {:noreply, assign(socket, editing?: false, form: nil)}
  end

  def handle_event("save_series", %{"series" => attrs}, socket) do
    case Catalog.update_series(socket.assigns.series, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing?: false, form: nil)
         |> put_flash(:info, "Series updated.")
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("ask_cancel_series", _params, socket) do
    {:noreply, assign(socket, confirming: :cancel, editing?: false)}
  end

  def handle_event("ask_delete_series", _params, socket) do
    {:noreply, assign(socket, confirming: :delete, editing?: false)}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_cancel_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.cancel_series(socket.assigns.series, actor) do
      {:ok, _} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Series cancelled.") |> reload()}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't cancel the series.")}
    end
  end

  def handle_event("confirm_delete_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_series(socket.assigns.series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Series deleted.")
         |> push_navigate(to: ~p"/series")}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the series.")}
    end
  end
```
Add a `{:series_deleted, id}` `handle_info` BEFORE the existing catch-all `def handle_info(_message, socket)`:
```elixir
  def handle_info({:series_deleted, id}, socket) do
    if id == socket.assigns.series.id do
      {:noreply,
       socket
       |> put_flash(:info, "This series was deleted.")
       |> push_navigate(to: ~p"/series")}
    else
      {:noreply, socket}
    end
  end
```
In `render/1`, add the admin controls + edit form + confirm panels just after the `<.link navigate={~p"/series"}>` line (before the poster `<div class="mb-8 flex gap-4">`):
```elixir
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <button type="button" class="btn btn-sm" phx-click="edit_series">Edit</button>
        <button type="button" class="btn btn-sm btn-warning" phx-click="ask_cancel_series">
          Cancel series
        </button>
        <button type="button" class="btn btn-sm btn-error" phx-click="ask_delete_series">
          Delete series
        </button>
      </div>

      <.form
        :if={@editing?}
        for={@form}
        id="series-form"
        phx-submit="save_series"
        class="mb-6 flex flex-wrap items-end gap-2"
      >
        <.input field={@form[:title]} type="text" label="Title" />
        <.input field={@form[:year]} type="number" label="Year" />
        <button class="btn btn-sm btn-primary" type="submit">Save</button>
        <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit_series">Cancel</button>
      </.form>

      <div :if={@confirming == :cancel} class="mb-6 flex items-center gap-2">
        <span class="text-sm">Cancel this series? Removes its downloads and unmonitors everything.</span>
        <button class="btn btn-sm btn-warning" phx-click="confirm_cancel_series">Confirm cancel</button>
        <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
      </div>

      <div :if={@confirming == :delete} class="mb-6 flex items-center gap-2">
        <span class="text-sm">
          Delete this series and its seasons/episodes? (Library files are left on disk.)
        </span>
        <button class="btn btn-sm btn-error" phx-click="confirm_delete_series">Confirm delete</button>
        <button class="btn btn-sm btn-ghost" phx-click="dismiss_confirm">Keep</button>
      </div>
```

- [ ] **Step 4: Run, expect PASS** — `mix test test/cinder_web/live/series_detail_live_test.exs`.

- [ ] **Step 5: Commit** —
```bash
git add lib/cinder_web/live/series_detail_live.ex test/cinder_web/live/series_detail_live_test.exs
git commit -m "web: SeriesDetailLive admin edit/cancel/delete controls + series_deleted nav

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

### Task 8: `SeriesLive` — admin-gated cancel/delete on the "Added series" cards (+ full-gate run)

**Files:**
- Modify: `lib/cinder_web/live/series_live.ex` (subscribe to `"series"` + drop deleted rows; add cancel/delete confirm controls inside the existing `@current_scope.user.role == :admin` section ~line 86; add `handle_info` + catch-all)
- Test: `test/cinder_web/live/series_live_test.exs` (append admin cancel/delete + the existing non-admin gating)

**Interfaces:**
- Consumes: `Catalog.list_series/0` (existing), `Catalog.cancel_series/2` + `Catalog.delete_series/2` (Task 3), `Catalog.subscribe_series/0`, `{:series_updated, _}` / `{:series_deleted, id}`. `socket.assigns.current_scope.user` (the role gate precedent at ~line 81 of series_live.ex and the audit actor).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test** — append to `test/cinder_web/live/series_live_test.exs`. First confirm its current header so the additions match (it likely uses `register_and_log_in_admin` and a TMDB stub); add at minimum:
```elixir
  # NOTE: ensure the test module has `import Mox`, `setup :set_mox_global`, and
  # `setup :register_and_log_in_admin` at the top (add them if absent).

  test "admin deletes an added series from the list", %{conn: conn} do
    series =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Deletable",
        monitored: true,
        monitor_strategy: :all
      })

    {:ok, lv, _html} = live(conn, ~p"/series")
    lv |> element(~s|button[phx-click="ask_delete_series"][phx-value-id="#{series.id}"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete_series"][phx-value-id="#{series.id}"]|) |> render_click()

    assert Repo.get(Cinder.Catalog.Series, series.id) == nil
    refute render(lv) =~ "series-row-#{series.id}"
  end

  test "a non-admin does not see the admin series controls", %{conn: conn} do
    Repo.insert!(%Cinder.Catalog.Series{
      tmdb_id: System.unique_integer([:positive]),
      title: "Hidden",
      monitored: true,
      monitor_strategy: :all
    })

    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, _lv, html} = live(conn, ~p"/series")
    refute html =~ "ask_delete_series"
    refute html =~ "Added series"
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `mix test test/cinder_web/live/series_live_test.exs:<admin deletes line>` → fails: no `ask_delete_series` button rendered.

- [ ] **Step 3: Implement** — edit `lib/cinder_web/live/series_live.ex`. In `mount/3`, subscribe + seed confirm state:
```elixir
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe_series()

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false, confirming: nil)
     |> assign(series: Catalog.list_series())}
  end
```
Add these `handle_event/3` clauses BEFORE the existing catch-all:
```elixir
  def handle_event("ask_cancel_series", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:cancel, id})}
  end

  def handle_event("ask_delete_series", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming: {:delete, id})}
  end

  def handle_event("dismiss_confirm", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("confirm_cancel_series", %{"id" => id}, socket) do
    run_series_op(socket, id, &Catalog.cancel_series/2, "Series cancelled.", "Couldn't cancel the series.")
  end

  def handle_event("confirm_delete_series", %{"id" => id}, socket) do
    run_series_op(socket, id, &Catalog.delete_series/2, "Series deleted.", "Couldn't delete the series.")
  end
```
Add the private helper + `handle_info` (the module currently has NO `handle_info` — add the catch-all too, per the spec's "newly-subscribed views need a catch-all"):
```elixir
  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    actor = socket.assigns.current_scope.user
    series = Enum.find(socket.assigns.series, &(to_string(&1.id) == id))

    case series && op.(series, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirming: nil, series: Catalog.list_series())
         |> put_flash(:info, ok_msg)}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, err_msg)}
    end
  end

  @impl true
  def handle_info({:series_updated, _id}, socket) do
    {:noreply, assign(socket, series: Catalog.list_series())}
  end

  def handle_info({:series_deleted, _id}, socket) do
    {:noreply, assign(socket, series: Catalog.list_series())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
```
In `render/1`, replace the admin section's card link block so each added-series card gets a stable id + admin controls. Change the existing `<.link :for={s <- @series} navigate={~p"/series/#{s.id}"} ...>` block to wrap each card and append controls:
```elixir
      <section :if={@current_scope.user.role == :admin}>
        <h2 class="pb-4 text-lg font-semibold leading-8">Added series</h2>
        <p :if={@series == []} class="text-base-content/60">No series added yet.</p>
        <div id="series-list" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <div :for={s <- @series} id={"series-row-#{s.id}"} class="space-y-2">
            <.link navigate={~p"/series/#{s.id}"} class="block">
              <.series_card series={s}>
                <span class="link link-primary text-sm">Configure monitoring →</span>
              </.series_card>
            </.link>

            <div class="flex gap-2">
              <button
                type="button"
                class="btn btn-xs btn-warning"
                phx-click="ask_cancel_series"
                phx-value-id={s.id}
              >
                Cancel
              </button>
              <button
                type="button"
                class="btn btn-xs btn-error"
                phx-click="ask_delete_series"
                phx-value-id={s.id}
              >
                Delete
              </button>
            </div>

            <div :if={@confirming == {:cancel, to_string(s.id)}} class="flex items-center gap-2">
              <span class="text-xs">Cancel & unmonitor?</span>
              <button class="btn btn-xs btn-warning" phx-click="confirm_cancel_series" phx-value-id={s.id}>
                Confirm
              </button>
              <button class="btn btn-xs btn-ghost" phx-click="dismiss_confirm">Keep</button>
            </div>

            <div :if={@confirming == {:delete, to_string(s.id)}} class="flex items-center gap-2">
              <span class="text-xs">Delete record? (files kept)</span>
              <button class="btn btn-xs btn-error" phx-click="confirm_delete_series" phx-value-id={s.id}>
                Confirm
              </button>
              <button class="btn btn-xs btn-ghost" phx-click="dismiss_confirm">Keep</button>
            </div>
          </div>
        </div>
      </section>
```

- [ ] **Step 4: Run, expect PASS (then the FULL gate)** — `mix test test/cinder_web/live/series_live_test.exs` then run the whole gate `mix test` (compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite). Fix any credo/format/warning traps (`@impl true` on the new `handle_info`, no unused vars, alias ordering, `mix format`).

- [ ] **Step 5: Commit** —
```bash
mix format
git add lib/cinder_web/live/series_live.ex test/cinder_web/live/series_live_test.exs
git commit -m "web: SeriesLive admin cancel/delete on added-series cards + series subscription

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CEtMcQ5fgpREWrjcKe2vV5"
```

---

Relevant absolute paths (in CT 113 at `/root/cinder`): context `lib/cinder/catalog.ex`, schemas `lib/cinder/catalog/{movie,series,grab,episode,season}.ex`, LiveViews `lib/cinder_web/live/{movies_live,grabs_live,series_live,series_detail_live}.ex`, router `lib/cinder_web/router.ex`, components `lib/cinder_web/components/core_components.ex`, tests `test/cinder/catalog_admin_test.exs` + `test/cinder_web/live/{movies_live,grabs_live,series_live,series_detail_live}_test.exs` + `test/cinder_web/components/status_badge_test.exs`. Spec: `/root/cinder/docs/superpowers/specs/2026-06-23-admin-crud-design.md`.

---

# Phase 3 — Requests R/D


### Task 1: `Cinder.Requests.list_requests/0` — list all requests with status, preload `:user`

**Files:**
- Test: `test/cinder/requests_test.exs` (add a `describe "list_requests/0"` block near the end of the module, after the existing `describe "season requests"`)
- Modify: `lib/cinder/requests.ex` (add `list_requests/0` next to the existing `list_pending/0`, around line 17–21)

**Interfaces:**
- Consumes: `Cinder.AccountsFixtures.user_fixture/0`, `admin_fixture/0`; `Cinder.Requests.create_request/2`; `Cinder.Requests.deny_request/3`; `Cinder.Catalog.add_to_watchlist/1` (only if needed — not needed here); `Cinder.Repo`.
- Produces: `Cinder.Requests.list_requests/0 :: [%Cinder.Requests.Request{}]` — every request regardless of status, `order_by: [desc: r.id]`, `preload: [:user]`. Consumed by Task 3 (`RequestsLive`).

- [ ] **Step 1: Write the failing test** — append this block to `test/cinder/requests_test.exs`, immediately before the final closing `end` of the module:

```elixir
  describe "list_requests/0" do
    test "returns requests of every status, newest first, with :user preloaded" do
      user = user_fixture()
      admin = admin_fixture()

      # pending (non-admin, no auto-approve)
      {:ok, pending} = Requests.create_request(user, @attrs)
      # denied
      {:ok, to_deny} = Requests.create_request(user, Map.put(@attrs, :target_id, 604))
      {:ok, denied} = Requests.deny_request(to_deny, admin, "nope")
      # approved (admin auto-approves its own)
      {:ok, approved} = Requests.create_request(admin, Map.put(@attrs, :target_id, 605))

      results = Requests.list_requests()

      assert Enum.map(results, & &1.id) == [approved.id, denied.id, pending.id]
      assert Enum.map(results, & &1.status) == [:approved, :denied, :pending]
      # :user is preloaded (not a NotLoaded struct)
      assert Enum.all?(results, &match?(%Cinder.Accounts.User{}, &1.user))
    end

    test "returns [] when there are no requests" do
      assert Requests.list_requests() == []
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/requests_test.exs'`
  Expected: `(UndefinedFunctionError) function Cinder.Requests.list_requests/0 is undefined or private` (the suite gate will also fail compile on the call until Step 3).

- [ ] **Step 3: Implement** — in `lib/cinder/requests.ex`, add `list_requests/0` directly after the existing `list_pending/0` function (after its closing `end`, around line 21):

```elixir
  def list_requests do
    Repo.all(from r in Request, order_by: [desc: r.id], preload: [:user])
  end
```

(`import Ecto.Query`, `alias Cinder.Repo`, and `alias Cinder.Requests.Request` are already present at the top of the module — no new aliases needed, so no credo alias-order churn.)

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/requests_test.exs'`
  Expected: all tests in the file pass (green).

- [ ] **Step 5: Commit** —
```bash
pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && RTK_SHIM_OFF=1 git add lib/cinder/requests.ex test/cinder/requests_test.exs && RTK_SHIM_OFF=1 git commit -m "requests: list_requests/0 — all requests, newest-first, :user preloaded"'
```

---

### Task 2: `Cinder.Requests.delete_request/2` — audited delete

**Files:**
- Test: `test/cinder/requests_test.exs` (add a `describe "delete_request/2"` block after the `list_requests/0` block from Task 1)
- Modify: `lib/cinder/requests.ex` (add `delete_request/2` after `deny_request/3`, before the private `create_approved/3` clauses, around line 116; add `alias Cinder.Audit` to the alias list)

**Interfaces:**
- Consumes: `Cinder.Audit.log(actor, action, entity, detail \\ %{}) :: {:ok, %Cinder.Audit.AdminAudit{}} | {:error, %Ecto.Changeset{}}` (Phase 0 — called INSIDE the `Repo.transaction`, after the guard, before commit, so a rolled-back delete leaves no orphan audit row; `entity` here is the persisted `%Request{}` → `entity_type` `"Request"`, `entity_id` = `request.id`); `Cinder.Repo.transaction/1`, `Repo.delete/1`, `Repo.rollback/1`; `Cinder.AccountsFixtures.user_fixture/0`, `admin_fixture/0`; `Cinder.Requests.create_request/2`.
- Produces: `Cinder.Requests.delete_request(%Cinder.Requests.Request{}, %Cinder.Accounts.User{}) :: {:ok, %Cinder.Requests.Request{}} | {:error, %Ecto.Changeset{}}`. Consumed by Task 3 (`RequestsLive`).

- [ ] **Step 1: Write the failing test** — append this block to `test/cinder/requests_test.exs`, immediately after the `describe "list_requests/0"` block. The module is already `use Cinder.DataCase, async: false` (required: `delete_request/2` opens a `Repo.transaction`, which the single-connection Sandbox needs `async: false` for) and already imports `Mox` and `Cinder.AccountsFixtures`:

```elixir
  describe "delete_request/2" do
    test "deletes the request and returns the deleted struct" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)

      assert {:ok, deleted} = Requests.delete_request(req, admin)
      assert deleted.id == req.id
      assert Repo.get(Cinder.Requests.Request, req.id) == nil
    end

    test "writes an admin_audit row (in-transaction) recording the actor and request" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)

      {:ok, _deleted} = Requests.delete_request(req, admin)

      audit = Repo.one(Cinder.Audit.AdminAudit)
      assert audit.actor_id == admin.id
      assert audit.action == "delete_request"
      assert audit.entity_type == "Request"
      assert audit.entity_id == req.id
    end

    test "deleting a non-pending request leaves any spawned catalog row in place (orphan)" do
      # An admin's own request auto-approves AND creates the movie row.
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(admin, @attrs)
      assert req.status == :approved
      assert [%Movie{tmdb_id: 603}] = Catalog.list_by_status(:requested)

      {:ok, _deleted} = Requests.delete_request(req, admin)

      # No FK request -> movie: the catalog row survives the request deletion.
      assert [%Movie{tmdb_id: 603}] = Catalog.list_by_status(:requested)
    end

    test "deleting a denied request re-opens requests_pending_unique (title requestable again)" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)
      {:ok, denied} = Requests.deny_request(req, admin, "no")

      {:ok, _deleted} = Requests.delete_request(denied, admin)

      # With the denied row gone, the same target can be requested fresh.
      assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
    end
  end
```

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/requests_test.exs'`
  Expected: `(UndefinedFunctionError) function Cinder.Requests.delete_request/2 is undefined or private` (and the suite gate fails compile on the call) until Step 3.

- [ ] **Step 3: Implement** — first add the alias. In `lib/cinder/requests.ex` the alias block (lines ~4–9) currently is:

```elixir
  alias Cinder.Accounts.User
  alias Cinder.Catalog
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests.Request
  alias Cinder.Settings
```

Insert `alias Cinder.Audit` to keep alphabetical order (credo `--strict` enforces alias ordering — `Audit` sorts before `Accounts.User`... no: `Cinder.Accounts.User` < `Cinder.Audit` alphabetically, so it goes second):

```elixir
  alias Cinder.Accounts.User
  alias Cinder.Audit
  alias Cinder.Catalog
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests.Request
  alias Cinder.Settings
```

Then add `delete_request/2` after the `deny_request(%Request{}, _admin, _reason)` clause (around line 116), before the `defp create_approved` definitions:

```elixir
  @doc """
  Deletes a request as an admin and records an `admin_audit` row in the same
  transaction.

  No FK links a request to the catalog row it may have spawned, so deleting a
  request does NOT remove an approved movie/series. Deleting a non-pending
  (denied/approved) request also re-opens the partial `requests_pending_unique`
  index, so the same title becomes requestable again. The UI surfaces both as a
  warning (see `CinderWeb.RequestsLive`); this function does not undo either.
  """
  def delete_request(%Request{} = request, %User{} = admin) do
    Repo.transaction(fn ->
      with {:ok, deleted} <- Repo.delete(request),
           {:ok, _audit} <-
             Audit.log(admin, "delete_request", deleted, %{
               status: deleted.status,
               target_type: deleted.target_type,
               target_id: deleted.target_id,
               title: deleted.title
             }) do
        deleted
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
```

(`Repo.transaction` returns `{:ok, deleted}` on success and `{:error, changeset}` on rollback, matching the `Repo.transaction(fn -> ... end)` precedent already in this module at `create_pending/2`. `Audit.log/4` is called inside the transaction, after the delete, per the Phase 0 contract — a rolled-back delete leaves no orphan audit row.)

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder/requests_test.exs'`
  Expected: green (all `delete_request/2` and prior tests pass).

- [ ] **Step 5: Commit** —
```bash
pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && RTK_SHIM_OFF=1 git add lib/cinder/requests.ex test/cinder/requests_test.exs && RTK_SHIM_OFF=1 git commit -m "requests: delete_request/2 — audited, in-txn; documents orphan + re-request semantics"'
```

---

### Task 3: Extend `RequestsLive` — list ALL requests with status badges + delete (confirm panel + warning)

**Files:**
- Test: `test/cinder_web/live/requests_live_test.exs` (add new tests after the existing ones, before the final module `end`)
- Modify: `lib/cinder_web/live/requests_live.ex` (whole file: switch from `pending`-only to `requests` (all), add `confirming_delete` assign, `start_delete`/`cancel_delete`/`delete` events, the confirm panel + warning text in `render/1`, and a `{:request_deleted, _}`-tolerant `handle_info`)

**Interfaces:**
- Consumes: `Cinder.Requests.list_requests/0` (Task 1); `Cinder.Requests.delete_request/2` (Task 2); existing `Cinder.Requests.subscribe/0`, `approve_request/2`, `deny_request/3`; existing `CinderWeb` component `request_status_badge/1` (defined in `core_components.ex`, covers `:pending`/`:approved`/`:denied` — auto-imported via `use CinderWeb, :live_view`); `socket.assigns.current_scope.user` (the server-side admin actor — never a client `phx-value` id); ConnCase `register_and_log_in_admin`, `log_in_user/2`; `Cinder.AccountsFixtures.user_fixture/0`.
- Produces: nothing consumed downstream (terminal UI for Phase 3).

- [ ] **Step 1: Write the failing test** — append these tests to `test/cinder_web/live/requests_live_test.exs`, before the module's final `end`. The file is already `use CinderWeb.ConnCase, async: false`, imports `Phoenix.LiveViewTest`, `Mox`, `Cinder.AccountsFixtures`, and runs `setup :register_and_log_in_admin` + `setup :set_mox_global`:

```elixir
  test "lists requests of every status with a badge", %{conn: conn} do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, _pending} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 1, title: "Pend"})
    {:ok, to_deny} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 2, title: "Den"})
    {:ok, _denied} = Cinder.Requests.deny_request(to_deny, admin, "no")

    {:ok, _lv, html} = live(conn, ~p"/requests")
    assert html =~ "Pend"
    assert html =~ "Den"
    # status badges render (request_status_badge prints the status atom)
    assert html =~ "pending"
    assert html =~ "denied"
  end

  test "deleting a request shows the orphan/re-request warning then removes it", %{conn: conn} do
    user = user_fixture()
    {:ok, req} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 3, title: "ToDelete"})

    {:ok, lv, _html} = live(conn, ~p"/requests")

    # open the confirm panel for this request
    confirm_html = lv |> element("button[phx-click='start_delete'][phx-value-id='#{req.id}']") |> render_click()
    assert confirm_html =~ "Deleting a request does not remove"
    assert confirm_html =~ "can be requested again"

    # confirm the delete
    lv |> element("button[phx-click='delete'][phx-value-id='#{req.id}']") |> render_click()

    assert Cinder.Repo.get(Cinder.Requests.Request, req.id) == nil
    refute render(lv) =~ "ToDelete"
  end

  test "cancel_delete closes the confirm panel without deleting", %{conn: conn} do
    user = user_fixture()
    {:ok, req} = Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 4, title: "Keep"})

    {:ok, lv, _html} = live(conn, ~p"/requests")
    lv |> element("button[phx-click='start_delete'][phx-value-id='#{req.id}']") |> render_click()
    lv |> element("button[phx-click='cancel_delete']") |> render_click()

    assert Cinder.Repo.get(Cinder.Requests.Request, req.id)
    assert render(lv) =~ "Keep"
  end

  test "delete with a forged non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "delete", %{"id" => "not-an-int"})
    assert render(lv) =~ "Requests"
  end

  test "delete with an unknown id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "delete", %{"id" => "999999"})
    assert render(lv) =~ "Requests"
  end
```

Note: the existing tests in this file assert `render(lv) =~ "Pending requests"`. Because Step 3 renames the heading to `"Requests"`, update those five existing robustness tests (`approve with non-integer id ...`, `start_deny ...`, `deny ...`, `unknown event name ...`) to assert `render(lv) =~ "Requests"` instead of `=~ "Pending requests"`. Do that edit in Step 3 alongside the LiveView change so the file compiles consistently.

- [ ] **Step 2: Run it, expect FAIL** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/requests_live_test.exs'`
  Expected: the new tests fail — e.g. `element("button[phx-click='start_delete']...")` raises because no such element exists yet, and the badge/warning assertions fail (`html` has no `start_delete` button or warning text).

- [ ] **Step 3: Implement** — replace the entire contents of `lib/cinder_web/live/requests_live.ex` with:

```elixir
defmodule CinderWeb.RequestsLive do
  @moduledoc """
  Admin requests screen at `/requests`. Lists every request with a status badge,
  supports approve/deny on pending rows, and a confirm-then-delete on any row.

  Delete warning (intentional, surfaced in the confirm panel): there is no FK
  from a request to the catalog row it spawned, so deleting a request does NOT
  remove an approved movie/series; and deleting a non-pending request re-opens
  the `requests_pending_unique` index, making the title requestable again.
  """
  use CinderWeb, :live_view
  alias Cinder.Requests

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Requests.subscribe()

    {:ok,
     assign(socket, requests: Requests.list_requests(), denying: nil, confirming_delete: nil)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    req = find_request(socket, id)

    case req && Requests.approve_request(req, socket.assigns.current_scope.user) do
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't approve that request — please try again.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    req = find_request(socket, id)
    if req, do: Requests.deny_request(req, socket.assigns.current_scope.user, reason)
    {:noreply, assign(socket, denying: nil)}
  end

  def handle_event("start_deny", %{"id" => id}, socket) do
    {:noreply, assign(socket, denying: id)}
  end

  def handle_event("start_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_delete: id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming_delete: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    req = find_request(socket, id)
    if req, do: Requests.delete_request(req, socket.assigns.current_scope.user)

    {:noreply,
     socket |> assign(confirming_delete: nil, requests: Requests.list_requests())}
  end

  # The event payload is client-controlled; ignore any malformed/forged frame
  # rather than crashing the LiveView on an unmatched clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _req}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign(socket, requests: Requests.list_requests())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Match a row by its (client-supplied, string) id without raising on garbage input.
  defp find_request(socket, id), do: Enum.find(socket.assigns.requests, &(to_string(&1.id) == id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Requests<:subtitle>Approve, deny, or delete catalog requests.</:subtitle>
      </.header>

      <ul :if={@requests != []} class="space-y-3">
        <li
          :for={r <- @requests}
          class="card bg-base-200 p-4 flex flex-col gap-3"
        >
          <div class="flex flex-row items-center gap-4">
            <img
              :if={r.poster_path}
              src={"https://image.tmdb.org/t/p/w92" <> r.poster_path}
              alt={r.title}
              class="w-12 rounded"
            />
            <div class="flex-1">
              <span class="font-semibold">
                {if r.target_type == "season",
                  do: "#{r.title} — Season #{r.season_number}",
                  else: r.title}
              </span>
              <span :if={r.year} class="opacity-60">({r.year})</span>
              <span class="text-sm opacity-60">— {r.user.email}</span>
            </div>
            <.request_status_badge status={r.status} />
            <button
              :if={r.status == :pending}
              class="btn btn-primary btn-sm"
              phx-click="approve"
              phx-value-id={r.id}
            >
              Approve
            </button>
            <form
              :if={r.status == :pending and @denying == to_string(r.id)}
              phx-submit="deny"
              class="flex gap-2"
            >
              <input type="hidden" name="_id" value={r.id} />
              <input
                type="text"
                name="reason"
                placeholder="Reason"
                class="input input-sm input-bordered"
              />
              <button class="btn btn-error btn-sm" type="submit">Confirm deny</button>
            </form>
            <button
              :if={r.status == :pending and @denying != to_string(r.id)}
              class="btn btn-ghost btn-sm"
              phx-click="start_deny"
              phx-value-id={r.id}
            >
              Deny
            </button>
            <button
              :if={@confirming_delete != to_string(r.id)}
              class="btn btn-ghost btn-sm text-error"
              phx-click="start_delete"
              phx-value-id={r.id}
            >
              Delete
            </button>
          </div>

          <div
            :if={@confirming_delete == to_string(r.id)}
            class="alert alert-warning flex flex-col items-start gap-2"
          >
            <p class="text-sm">
              Deleting a request does not remove any movie or series it already created —
              that catalog row stays. If this request was denied or approved, the same title
              can be requested again afterwards.
            </p>
            <div class="flex gap-2">
              <button
                class="btn btn-error btn-sm"
                phx-click="delete"
                phx-value-id={r.id}
              >
                Delete request
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="cancel_delete">Cancel</button>
            </div>
          </div>
        </li>
      </ul>
      <p :if={@requests == []} class="opacity-60">No requests.</p>
    </Layouts.app>
    """
  end
end
```

Then update the five existing robustness tests in `test/cinder_web/live/requests_live_test.exs` that assert `render(lv) =~ "Pending requests"` — change each to `render(lv) =~ "Requests"` (the new `<.header>` heading). The affected tests: `"approve with non-integer id does not crash the LiveView"`, `"start_deny with non-integer id does not crash the LiveView"`, `"deny with non-integer _id does not crash the LiveView"`, `"unknown event name does not crash the LiveView"`. (The earlier `"lists pending and approves"` test asserts `html =~ "The Matrix"` which still holds.)

- [ ] **Step 4: Run, expect PASS** — `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test test/cinder_web/live/requests_live_test.exs'`
  Expected: green. Then run the full gate to confirm format/credo/warnings + whole suite: `pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && mix test'`. If `mix format --check-formatted` flags the rewritten LiveView, run `mix format lib/cinder_web/live/requests_live.ex test/cinder_web/live/requests_live_test.exs` and re-run `mix test`.

- [ ] **Step 5: Commit** —
```bash
pct exec 113 -- env -i TMPDIR=/tmp HOME=/root bash -lc 'cd /root/cinder && RTK_SHIM_OFF=1 git add lib/cinder_web/live/requests_live.ex test/cinder_web/live/requests_live_test.exs && RTK_SHIM_OFF=1 git commit -m "requests UI: list all requests with status badges + confirm-delete (orphan/re-request warning)"'
```

---

Relevant absolute paths (inside CT 113 at `/root/cinder`):
- `lib/cinder/requests.ex` — `list_requests/0`, `delete_request/2`
- `lib/cinder_web/live/requests_live.ex` — extended LiveView
- `test/cinder/requests_test.exs` — context tests
- `test/cinder_web/live/requests_live_test.exs` — LiveView interaction tests

Key consumed facts verified against the live codebase: `request_status_badge/1` already exists in `core_components.ex` (covers `:pending`/`:approved`/`:denied`, no badge-crash risk); `requests_test.exs` is already `use Cinder.DataCase, async: false` and imports Mox + AccountsFixtures (so the transactional `delete_request/2` test needs no setup changes); `requests_live_test.exs` already runs `register_and_log_in_admin` + `set_mox_global` and has the non-admin redirect test, so authorization coverage for `/requests` already exists; `socket.assigns.current_scope.user` is the established server-side admin actor in this LiveView; `Repo.transaction(fn -> ... end)` with `Repo.rollback/1` returning `{:ok, val}`/`{:error, reason}` is the existing `create_pending/2` precedent in the same module.