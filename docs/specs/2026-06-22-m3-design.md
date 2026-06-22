# M3 — Onboarding wizard + requester UX (design)

> Milestone M3 of ROADMAP.md Part II. Goal: make the multi-user **movies** product
> installable-and-operable by a stranger. Built on the seams M2 left. One DB migration
> (`request_quota`); `setup_complete` and `library_path` use the Settings KV store.

## Locked decisions

- **Quota shape:** concurrent-pending count. `users.request_quota` nullable int, `nil` = unlimited.
  Admins and the `auto_approve_all` path bypass (they never sit in `:pending`).
- **Wizard strictness:** require all required services to validate `:ok` via `Health` before
  `setup_complete` can be set ("require all green").
- **Library path:** moves into the Settings store + the wizard (was `LIBRARY_PATH` env-only).
- **Quota-setting UI:** include a minimal admin `/users` LiveView (role + inline quota).
- **Notifier default:** `Cinder.Notifier.Log` (log-only). In-app reactivity already rides the
  existing `"requests"`/`"movies"` PubSub topics; the behaviour is the seam for real transports
  (Discord/email) later. No new notifications topic in M3.
- **Email confirmation:** stays off (no SMTP). `register_user/1` already auto-confirms.
- **Attribution:** stays on the `Request` row only (no `requested_by` on `Movie`).

## A. First-run wizard

**Detection (no migration):**
- `Settings.setup_complete?/0` ⇒ `get("setup_complete") == "true"` (mirrors `auto_approve_all?`).
- `Accounts.admin_exists?/0` ⇒ `Repo.aggregate(User, :count) > 0` (the first user is always admin).

**Routing (reuse existing auth; no router plug):**
- Admin creation reuses the existing `/users/register` (first user → admin, auto-confirmed,
  auto-logged-in). No custom admin-creation step.
- `UserAuth.signed_in_path/1` becomes setup-aware: returns `/setup` when setup incomplete and the
  user is admin, else `/`.
- New `on_mount :require_setup` on the `:authenticated` and `:admin` live_sessions: while
  incomplete, redirect admins → `/setup`, park non-admins → `/users/log-in` (flash). The
  `:current_user` session (register/login) stays open so the first admin can be created.
- `/setup` lives in its own `:setup` live_session (`require_authenticated` + `require_admin`);
  it redirects to `/` once `setup_complete?` is true (no loop).

**`SetupLive` at `/setup`:** single LiveView, services step only. Reuses the Settings grouped
form + per-service `Health` Test buttons. Validates five things: TMDB, indexer, ≥1 download
client, media server, **library path**. Holds the latest `Health` result per service in assigns;
**Finish is disabled until every required service last-tested `:ok`**. Finish ⇒
`Settings.put("setup_complete", "true")` ⇒ redirect `/`. Health tests SAVED config, so the wizard
saves before testing (same as `SettingsLive`).

**Library path into Settings:** add `library_path` as a Settings special key handled like
`media_server_type` — an `apply_library_path/1` in `load_into_env/0` doing
`put_env(:cinder, :library_path, …)`, overlaying the env bootstrap (M1 pattern). New
`Health.check_service(:library)` validates via `Filesystem.mkdir_p/1` (writable-dir probe,
mockable through the existing `FilesystemMock`). Rendered in `/settings` too (a new `:library`
group) so it stays editable.

## B. Per-user quota (concurrent-pending)

- Migration `add_request_quota_to_users`: `add :request_quota, :integer` (nullable).
- Schema: `field :request_quota, :integer` on `User`; a changeset `quota_changeset/2`.
- Enforcement: first guard in `Requests.create_request/2` — for the non-admin, non-auto-approve
  path, count `status == :pending` requests for the user; if `>= request_quota`, return
  `{:error, :quota_exceeded}`. Admins and `auto_approve_all` bypass. `WatchlistLive.add/2` gains
  a `{:error, :quota_exceeded}` flash branch.
- Setting it: minimal admin **`UsersLive` at `/users`** (admin-gated) — lists users with email,
  role, and an inline `request_quota` number input; `Accounts.update_user_quota/2`.

## C. Requester UX

- **`MyRequestsLive` at `/my-requests`** (`:authenticated`, any user): `Requests.list_for_user/1`
  with request-status badges (Pending / Approved / Denied + reason); for approved titles, the
  movie's live pipeline state (→ Available). Live via `Requests.subscribe/0` + `Catalog.subscribe/0`.
- **Per-title badge on the discovery grid:** `WatchlistLive` builds two maps on mount/search —
  `tmdb_id => latest request status` (from `list_for_user/1`) and `tmdb_id => movie status` (from
  the global watchlist) — and renders one composite badge per result instead of always "Add":

  | User's relationship to title | Badge |
  |---|---|
  | none | **Add** button |
  | request pending | **Pending** |
  | request denied | **Denied** (Add re-enabled — partial unique index only blocks pending) |
  | request approved, movie not yet available | **Approved** |
  | movie `:available` | **Available** |

  ("Requested" from the roadmap's list is collapsed into "Approved" — same state for the
  requester.) Live updates patch the maps from both topics.
- **Nav:** root-layout menu gains **My requests** (all users) and **Requests / Status / Settings**
  (admin) — the admin pages have no nav entry today.

## D. `Cinder.Notifier`

- Behaviour `@callback notify(event) :: :ok`. Typed events: `{:request_approved, request}`,
  `{:movie_available, movie}`, `{:movie_failed, movie, reason}`.
- `Cinder.Notifier.Log` default (`Logger.info` per event). Config `:cinder, :notifier`, resolved
  at runtime via `Application.fetch_env!/2` (the `:tmdb`/`:filesystem`/`:media_server` pattern).
  `config/test.exs` → `Cinder.NotifierMock`; `Mox.defmock` in `test_helper.exs`.
- Call sites (explicit): approved → the two `tap_ok` funnels in `requests.ex`; available → after
  the `:available` transition in `poller.ex`; failed → funnel the poller's terminal-park sites
  through one new `park/3` helper that transitions **and** notifies (touches only the failure
  paths, leaving `Catalog.transition` the single state choke-point).

## E. Approval-queue polish

`RequestsLive` already shows the requester email; render the **poster** (`request.poster_path` is
stored but unrendered) + title.

## Data-model changes

One migration: `request_quota` on `users`. `setup_complete` + `library_path` are Settings KV (no
migration). No `requested_by` on `Movie`.

## Testing (done-when + per-piece)

- **Done-when chain** (extends `test/cinder/requests_test.exs` + the `poller_test.exs`
  drive-to-`:available` recipe): non-admin requests (pending, **no movie row**) → admin
  `approve_request/2` (movie at `:requested`, `req.user_id` preserved = attribution) → supervised
  Poller + Mox stubs → `Poller.poll/0` → movie `:available` + reloaded request approved/attributed
  + assert the `{:movie_available, movie}` notifier event (via `NotifierMock`).
- **Quota:** concurrent-pending limit blocks the N+1 request; admin/auto-approve bypass.
  `async: false`; restore `:cinder` settings env on exit (M1-overlay discipline).
- **Wizard:** Finish gating (disabled until five `:ok`), `setup_complete` flips, redirect
  behavior; `Health.check_service(:library)` via `FilesystemMock`.
- **Badges / My-requests:** LiveView tests mirroring `watchlist_live_test.exs` (composite badge
  per state, live PubSub patch).
- **Gating:** `/setup`, `/my-requests`, `/users` role/route gating in `authorization_test.exs`.

## Conventions

`mix test` (the alias: `--warnings-as-errors`, `format --check-formatted`, `credo --strict`,
suite) green. Every new behaviour gets a test. No network in tests. New config goes through the
Settings store, not new env vars (except `library_path` whose env bootstrap stays as the M7
docker default).
