# M2 — Accounts, Roles, Request/Approval — Design

**Milestone:** Part II / M2 (size **L**). **Date:** 2026-06-21.
**Branch:** `m2-accounts-roles-requests`.

> Council review: 2 rounds (3 perspective-diverse Claude reviewers; Claude-only harness, no
> cross-model roster). Round 1 surfaced ~12 material findings (the security spine, the
> non-existent "find-or-create" op, the `auto_approve_all` `nil→true` trap, router
> reconciliation, undercounted test churn) — all fixed. Round 2 confirmed every R1
> security/correctness finding ADDRESSED; remaining items were mechanical generator-claim
> corrections (bespoke auto-login + register-form password inputs, mandatory `:movie_created`
> handler, no-compile-error scope reframe, phantom `signed_in_path` override struck, two
> generated LiveView test rewrites) — now applied. **Consensus: implement-ready, no residual
> architectural disagreement.** Disclosed-not-fixed (deliberate user choices, beyond the
> Done-when): polymorphic `requests` now + the global `auto_approve_all` toggle — rationale for
> the former tempered (see Decision #2 note); re-confirm at review.

## Goal

Replace the shared Basic-auth password with **real local accounts** + an `admin`/`user`
role split + a **separate `requests` table that gates pipeline entry**. A non-admin "Add"
creates a *pending request* and writes **no** `:requested` movie; an admin approves to
create the movie. This is the security spine of the whole multi-user (Seerr) layer.

## Decisions (settled in brainstorming, 2026-06-21)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Auth model for a no-SMTP self-host | **Password + auto-confirm** registration; magic-link / reset / confirmation context code kept dormant (no SMTP needed). The magic-link **login form + mailbox banner are removed from the UI** (see §A). |
| 2 | `requests` target shape | **Polymorphic now** (`target_type` + `target_id` + display snapshot). ⚠️ **Rationale corrected by council** — see note below. |
| 3 | Auto-approve | Admins' own requests auto-approve **+ include the global `auto_approve_all` toggle now**. *(Toggle is roadmap-sanctioned for M2 but beyond the Done-when.)* |
| 4 | Registration policy | **Open self-registration**; first registrant = admin; exposure controlled by the optional outer Basic-auth gate (see §Risks). |
| — | Hashing lib | bcrypt (`--hashing-lib bcrypt`) → adds `bcrypt_elixir`. |
| — | Auth UI style | LiveView (`--live`). |

> **⚠️ Council correction to Decision #2's rationale:** "polymorphic now *avoids* the M4
> migration" is largely false. A movie request stores `target_id = tmdb_id` + a movie-shaped
> snapshot (title/year/poster). TV **episodes** need season+episode coordinates the snapshot
> can't carry, so M4 will migrate columns (or add a JSON payload) regardless. The only thing
> "polymorphic now" actually buys is the `target_type` discriminator column. Also note a
> `movies.id` FK is **impossible** at request time (the movie row doesn't exist until
> approval), so we store TMDB identity either way — the choice is purely "tag it with
> `target_type` now vs. add that column at M4." Kept as chosen; re-confirm at spec review.

## Why the gate must be in the data model (the threat)

`Cinder.Catalog.add_to_watchlist/1` (`catalog.ex:36`) does a direct `Repo.insert` at the
schema default `status: :requested`. The poller (`poller.ex:79-80`) consumes **every**
`:requested` row each tick via an unfiltered `list_by_status(:requested)` — no
ownership/approval predicate. **It is the only writer of a movie row, called only from
`WatchlistLive` (grep-verified).** Therefore the gate is "*who may call the create path*,"
enforced in the `Requests` context — not a hidden UI button. The `requests` partial-unique
index is a **dedup/UX** control, **not** the security control; the invariant is enforced
solely by `create_request` choosing the `:pending` branch and not creating a movie.

---

## Components

### A. Auth foundation (`phx.gen.auth`, adapted)

Generate with:

```
mix phx.gen.auth Accounts User users --live --hashing-lib bcrypt
```

Keep the generated, security-reviewed core unchanged: `Accounts.User`, `Accounts.UserToken`,
`Accounts.Scope`, `CinderWeb.UserAuth` (plug + `on_mount`), `UserNotifier`, session plumbing
(slots into the existing runtime `CinderWeb.Endpoint.session_options/0` seam; salts already
derive from `secret_key_base` in `runtime.exs`).

**Deviation — registration works with zero email.** Add a `User.registration_changeset/2`
(casts **email + password**, `validate_email`, `validate_password` min 12 / **max 72 bytes**,
hashes via the existing `maybe_hash_password`). Then `Accounts.register_user/1` is, concretely:

```elixir
def register_user(attrs) do
  Repo.transaction(fn ->                                  # atomic first-admin assignment
    role = if Repo.aggregate(User, :count) == 0, do: :admin, else: :user
    %User{}
    |> User.registration_changeset(attrs)                 # email + password (cast + validate + hash)
    |> Ecto.Changeset.put_change(:confirmed_at, now())    # auto-confirm — never from params
    |> Ecto.Changeset.put_change(:role, role)             # server-side only — never cast
    |> Repo.insert()
    |> case do
      {:ok, user} -> user
      {:error, cs} -> Repo.rollback(cs)
    end
  end)
end
```

Invariants this guarantees (each gets a test):
- `:role` and `:confirmed_at` are applied via `put_change` **after** the cast, so a crafted
  `user[role]=admin` / `user[confirmed_at]=…` param is structurally ignored.
- `confirmed_at` **and** `hashed_password` are set in the **same** insert — no path persists
  a confirmed-without-password or password-without-confirm user (closes the magic-link
  session-fixation edge the generator warns about).

**Register form HEEx (net-new):** the generated `registration_live` form is **email-only** —
add `password` + password-confirmation `.input`s. (Without them there's nothing to hash.)

**Immediate login (bespoke — NOT inherited):** the generated `registration_live` is a
passwordless magic-link flow that just `push_navigate`s to `/log-in`; there is no
`phx-trigger-action`/`trigger_submit` on it (that lives only in `login_live`). A LiveView
can't set the session cookie directly, so auto-login is real net-new code: on a successful
`register_user`, set a `trigger_submit` assign and render a hidden form
(`action={~p"/users/log-in"}`, `phx-trigger-action`) carrying the just-entered
email+password — `UserSessionController.create` re-verifies via
`get_user_by_email_and_password`, so it lines up. **Realistic fallback (closer to native):**
`push_navigate` to the login page (pre-filled). Pick the fallback if the hidden-form proves
fiddly; either way the register form needs the password inputs above.

**Dormant email flows, trimmed UI:** magic-link / password-reset / email-confirmation
**context** code stays (re-activates if a household configures SMTP). But the **magic-link
login form and the `local_mail_adapter?` "visit the mailbox" banner are removed from
`login_live`** so a no-SMTP user never clicks a silently-dead button — password login only.
The generated `confirmation_live_test` and `settings_live` email-change test stay green in
test (they run against `Swoosh.Adapters.Test`, already configured in `config/test.exs`); only
the *runtime* delivery is inert without SMTP.

The generated `UserAuth.signed_in_path/1` **already returns `~p"/"`** in this template version
— no override needed; the "login → discovery" flow holds out of the box.

### B. Roles

- Migration `add_role_to_users`: `add :role, :string, null: false, default: "user"`. Schema:
  `field :role, Ecto.Enum, values: [:admin, :user], default: :user`. (SQLite stores the enum
  as the string `"user"`/`"admin"`; the DB default must be the string `"user"`.)
- **`role` is never cast from params** — set server-side only, in `register_user` (§A).
- **First user = admin** via the transactional count check in `register_user`.
  `# ponytail: count+insert in one txn; multi-admin is allowed, so this only guards the first-row race, not a single-admin invariant.`
- Add `require_admin` (plug **and** `on_mount` clause) to `CinderWeb.UserAuth`, checking
  `current_scope && current_scope.user && current_scope.user.role == :admin` (mirror the
  generated `:require_authenticated` nil-guard). **`require_admin` is only ever stacked after
  `require_authenticated`** — `Scope.for_user(nil)` returns `nil` (not `%Scope{user: nil}`),
  so an unguarded `current_scope.user.role` would raise for anonymous requests.

### C. Routes (`router.ex`) — generator reconciliation is the top derail risk

The generator does **not** merge into Cinder's existing `scope "/", CinderWeb`; it **appends
new `scope "/"` blocks** for the auth routes (`/users/register`, `/users/log-in`,
`/users/settings`) and leaves the old scope (with `live "/"`, `/status`, `/settings`) intact.
Multiple `scope "/"` blocks compile fine and the generator never adds `live "/"`, so there's
**no forced compile error** — but the app routes still sit in the *public* old scope, so the
implementer must manually fold them into the new auth model (this is the reconciliation, driven
by wanting gating — not by the compiler):

- **Move the `:basic_auth` plug into the `:browser` pipeline** (instead of the standalone
  `:admin_auth` pipeline on one scope). This makes the optional outer Basic gate cover **every**
  browser route uniformly — app, auth, admin, `/dev` — and survives the generator adding new
  scopes. Realizes the roadmap's "keep the env Basic password as an optional outer
  reverse-proxy gate." The `:admin_auth` pipeline can then be deleted.
- The generator inserts `fetch_current_scope_for_user` into `:browser` after
  `:put_secure_browser_headers`.
- `live_session :authenticated` (`on_mount {UserAuth, :require_authenticated}`): `live "/", WatchlistLive`.
- `live_session :admin` (`on_mount {UserAuth, :require_admin}`): `"/status"`, `"/settings"`,
  `"/requests"`.
- Auth routes (login/register/user-settings): generated, public, redirect-if-authenticated.
  Delete the old `scope "/"` block after moving its three routes into the live_sessions.
- `/dev` scope (LiveDashboard + mailbox; `dev_routes`-only): `pipe_through [:browser,
  :require_authenticated_user, :require_admin]` — **plug** gating (these are not LiveViews, so
  `on_mount` does nothing for them), ordered after the scope-fetch plug. Test: a `:user` and
  anon both get 302/403 on `/dev/dashboard` and `/dev/mailbox`.

### D. Requests context (polymorphic) — the security spine

`create_requests` migration:

```
requests:
  user_id        references(:users) not null
  target_type    :string  not null        # "movie" (later "series"/"episode")
  target_id      :integer not null        # tmdb_id for movies
  title          :string                  # display snapshot — render queue w/o TMDB
  year           :integer
  poster_path    :string
  status         :string  not null default "pending"   # Ecto.Enum [:pending,:approved,:denied]
  denial_reason  :string
  approved_by_id references(:users)        # nullable
  timestamps()
# index (user_id), index (status)
# partial unique index (user_id, target_type, target_id) WHERE status = 'pending'
#   → dedup only (no double *pending* request); a denied/approved row does not block re-request.
#   → NOT a security control (see §Why).
```

`Cinder.Requests` (the single gate):

- `create_request(user, attrs)` — `attrs = %{target_type, target_id, title, year, poster_path}`.
  - If `user.role == :admin` **or** `Cinder.Settings.auto_approve_all?()` → **auto-approve**:
    `Catalog.find_or_create_at_requested(attrs)` (see below), insert the request already
    `:approved` (`approved_by_id`: the admin for admin-own; `nil` for the global toggle).
  - Else → insert `:pending`. **No movie row is created.**
  - Returns `{:ok, request} | {:error, changeset}` (dup-pending → unique error → flash).
- `approve_request(request, admin)` — **guard `status == :pending`** (mirror
  `Catalog.retry_movie`'s server-side guard); `find_or_create_at_requested`, set `:approved` +
  `approved_by_id`. Idempotent.
- `deny_request(request, admin, reason)` — **guard `status == :pending`**; set `:denied` +
  `denial_reason`. (Prevents a race where one admin denies an already-approved request while
  its movie downloads.)
- `list_pending/0`, `list_for_user/1`.
- Broadcasts on a new `"requests"` PubSub topic — message variants
  `{:request_created, r}` | `{:request_approved, r}` | `{:request_denied, r}`. The `/requests`
  queue subscribes and renders **only `status == :pending`** (an auto-approved request is
  created already `:approved` and must not show as pending).

**New `Catalog` primitive — `find_or_create_at_requested(attrs)`:** `add_to_watchlist/1` is
insert-only and returns `{:error, changeset}` on the `unique_constraint(:tmdb_id)` hit, so
"find-or-create via add_to_watchlist" is not a real operation. Define:

1. `get_by_tmdb_id(attrs.target_id)` (filtered conceptually by movie identity) → if found,
   **return it at its *current* status** (never reset an `:available`/`:downloading` movie back
   to `:requested`).
2. If absent, insert at `:requested`.
3. **Catch the `unique_constraint(:tmdb_id)` race** (two approvers / poller TOCTOU under WAL +
   `busy_timeout` — the write serializes but the get-then-insert window is still a logical
   TOCTOU) → on constraint error, re-fetch and return the existing row.

Movie *creation* legitimately bypasses `Catalog.transition` (transition is `Repo.update`-only).
A created movie currently emits **no** broadcast, so an approval-created movie won't appear on
an already-open `/` until reload. Fix: `find_or_create_at_requested` broadcasts
`{:movie_created, movie}` on the `"movies"` topic (≈3 lines + a `WatchlistLive` handler), and
document the carve-out in CLAUDE.md ("transition is the choke-point for *state changes*;
creation is a separate insert that broadcasts `:movie_created`"). **The matching
`WatchlistLive` `handle_info({:movie_created, movie}, …)` clause is MANDATORY:**
`WatchlistLive` currently has a single `handle_info({:movie_updated, _})` and **no catch-all**
(`watchlist_live.ex:53`), so an unmatched broadcast raises `FunctionClauseError` and crashes
every open `/` session. Add the clause (prepend the new movie to `@watchlist`); a defensive
catch-all `handle_info(_, socket)` is also wise.

### E. Pipeline-entry rewire

`WatchlistLive` "add" routes **all** adds through `Requests.create_request/2` using the
current user (`current_scope.user`). Admin → auto-approved (movie created, attributed to the
admin). `:user` (toggle off) → pending request, **no movie**. The poller pickup line is
unchanged. Flash: pending → "Requested — awaiting approval"; approved → existing copy.
**No reachable `add_to_watchlist` call may remain** outside the gate (grep-guard + test).
`/` deliberately does **not** reflect a user's own request status in M2 (per-title badges are
M3) — stated so it isn't flagged as missing.

Minimal admin **approval queue** at `/requests`: lists pending requests (title + requester
email), Approve button + a small **Deny reason form** (`phx-click` can't collect free text).
`mount` subscribes to `"requests"`; handlers add/remove rows; renders only `:pending`. The
poster-rich polish is M3.

### F. Auto-approve-all toggle

- Stored as a settings row; written via a **dedicated `Settings.put("auto_approve_all", v)`**
  call from its own settings event handler — **not** the registry form
  (`save_form/1`→`plan/2` is registry-bound and silently drops unknown params). `put/2` is not
  an authorization boundary; its safety is that the only caller is the admin-gated `/settings`.
- Read **live** via `Cinder.Settings.auto_approve_all?/0` ≙ `get("auto_approve_all") == "true"`
  → **`nil`/absent → `false`** (a fresh install gates by default). **Must not reuse
  `enabled?/1`** (whose `nil → true` would silently default auto-approve ON — total gate
  defeat) and must use string compare, not Elixir truthiness (`"false"` is truthy).
  `# ponytail: per-request DB read, fine at household scale.` Bypasses `load_into_env` (not a
  registry/env key) — simpler and always current.

---

## Data flow

```
login → "/" discovery (any authenticated user) → search (TMDB, mocked in test) → Add
  ├─ admin OR auto_approve_all  → Requests.create_request → auto-approve
  │                              → Catalog.find_or_create_at_requested (Movie :requested) → poller grabs
  └─ :user (toggle off)         → Requests.create_request → :pending, NO movie
                                   admin → /requests → Approve → Movie :requested → poller grabs
                                                     → Deny  → :denied + reason
```

## Error handling

- Duplicate pending request → partial-unique violation → `{:error, changeset}` → flash.
- Approve when the movie already exists (any status) → reused, **not reset**; request approved.
- Concurrent double-approve / poller TOCTOU → unique-constraint caught + re-fetched, one movie.
- `role` defaults to `:user`, never cast from params (no escalation via form).
- `approve_request`/`deny_request` no-op (or `{:error, :not_pending}`) unless `:pending`.
- Anonymous → redirect to login; `:user` on an admin route → redirect with flash.

## Migrations (additive, ordered)

1. `phx.gen.auth` (`users`, `users_tokens`).
2. `add_role_to_users`.
3. `create_requests` (+ indexes above).

## Generator housekeeping (don't get surprised)

- `bcrypt_elixir` is auto-injected into `mix.exs` deps (top of list; `mix format` reflows).
- `config :bcrypt_elixir, :log_rounds, 1` auto-injected into `config/test.exs` (fast hashing).
- The generator writes an **`AGENTS.md`** at the web root — this project uses `CLAUDE.md`.
  **Delete it** (config-hygiene) or fold anything useful into `CLAUDE.md`.
- The generator injects a **user menu** into the root layout (Register/Log-in/Log-out) — a
  visible UI change; place/style it acceptably.
- The generator edits `router.ex` (import + `fetch_current_scope_for_user` plug + appended
  scopes) but does **not** touch `application.ex` (Mailer/PubSub/DNSCluster already present).

## Test plan (every new behaviour gets a test)

**New:**
- **Security (Done-when core):** a `:user` `create_request` yields a `:pending` request and
  `Repo.aggregate(Movie, :count) == 0` / `Catalog.list_by_status(:requested) == []`; only
  `approve_request` creates the movie. (Proves the poller can't see it pre-approval.)
- `register_user` ignores a `role`/`confirmed_at` param (non-first user stays `:user`); never
  yields `confirmed_at: nil`.
- First-user-becomes-admin.
- Admin-own auto-approve creates the movie; `auto_approve_all` ON → a `:user` add creates it;
  fresh install (no row) → `auto_approve_all?() == false` → `:user` add stays `:pending`.
- Approve a request whose movie is already `:available` → stays `:available`.
- `approve`/`deny` guarded to `:pending`.
- Role/route gating: `:user` redirected from `/status`, `/settings`, `/requests`, `/dev/*`;
  anon → login; admin reaches all.

**Existing-test churn (budgeted — wider than first thought):**
- `watchlist_live_test`, `status_live_test`, `settings_live_test` — `/`, `/status`,
  `/settings` now require auth → add `log_in_user` (an **admin** user, so the existing
  "add → `:requested`" assertion holds via the admin auto-approve path).
- **`admin_auth_test.exs`** — its 3 tests asserting `GET /status` → 200 **without login** now
  get 302. Re-point the Basic-auth assertions at an always-public auth route (e.g.
  `/users/log-in`) so the outer-gate test stays meaningful and decoupled from account auth.
- **Generated-fixture chain:** `valid_user_attributes` (email-only) must supply a **password**,
  and the generated `register_user` describe block (asserts passwordless/unconfirmed) is
  rewritten for password+auto-confirm. `user_fixture` stays usable (auto-confirmed users still
  work).
- **Generated LiveView auth tests:** `registration_live_test` (asserts "creates account but
  does not log in" + the magic-link email flash) and `login_live_test` (the `#login_form_magic`
  element, `submit_magic` event, and `follow_trigger_action`) both assert the magic-link / no-
  auto-login behavior we're changing — rewrite them for password+auto-confirm and the trimmed
  login UI (or they fail).
- **`async: false` is load-bearing** (LiveView runs in its own process; `set_mox_global` +
  shared sandbox so the session-token row is cross-process visible). All new web tests stay
  `async: false`. SQLite forces every generated auth test synchronous (`phx.gen.auth.ex`
  emits no `async: true` for non-Postgres) → the web suite serializes and `mix test` slows;
  acceptable.

All generated code must pass the strict `mix test` alias (compile `--warnings-as-errors`,
`format --check-formatted`, `credo --strict`). **Run the generator in the branch first and
green it before building `Requests`** — don't trust the template read.

## Risks & accepted postures (security)

- **Open-admin-registration window.** With open registration (Decision #4) and the Basic gate
  **off by default**, a freshly deployed, un-proxied instance lets *whoever reaches it first*
  register the admin; a registration race could even mint a second admin (the txn closes the
  same-instant double-insert, but not "attacker registers before the owner"). **Accepted M2
  posture, documented, not silently shipped:** run M2 behind the env Basic-auth gate or a
  reverse-proxy/VPN until M3's first-run wizard owns admin creation. Add a **loud boot log
  warning** when `users == 0` **and** no Basic-auth is configured.
- The `:admin_auth` → `:browser` move keeps the outer gate over the whole app; don't let any
  new scope drop it.
- `Settings.put/2` is not an auth boundary — the admin route is. Don't expose it to non-admins.

## Done when (roadmap M2)

Conventions pass (`mix test` alias green) **+** a security test asserts a non-admin request
never reaches the poller until an admin approves (no movie row at `:requested` before
approval), and role/route gating is covered. — *Release checkpoint: internal-alpha (private).*

## Sub-session split (L milestone — `/clear` between)

1. **Auth + roles + routes:** run generator in-branch & green it; password+auto-confirm
   adaptation (`registration_changeset` + `register_user` + **register-form password inputs** +
   auto-login or login-redirect + fixtures + rewritten `registration_live_test`/
   `login_live_test`/context `register_user` tests); trim magic-link login UI; role column;
   `require_admin`; router reconciliation (move Basic→`:browser`, fold app routes into
   live_sessions, gate `/dev`, delete old scope); fix existing LiveView + `admin_auth` tests;
   delete `AGENTS.md`; boot warning. Green.
2. **Requests + rewire + toggle:** `find_or_create_at_requested` (+ `:movie_created`
   broadcast); `Requests` context + migration + state guards + PubSub; `create_request` gate;
   `WatchlistLive` rewire; `/requests` queue (subscribe + deny form); `auto_approve_all`
   setting + `/settings` checkbox + read helper. Green incl. security + auto-approve tests.
3. **Hardening:** review generated `auth_test.exs` against `credo --strict`; fill gating-test
   gaps; CLAUDE.md carve-out + env-vs-DB note; tidy flashes/copy.

## Out of scope for M2 (later milestones)

- Quotas, My-requests view, per-title badges, the `Notifier`, first-run wizard → **M3**.
- TV targets exercising the polymorphic `requests` table → **M4** (snapshot/coordinate columns
  migrate then regardless).
- Real SMTP / email confirmation enforcement → optional, post-M2.
