# Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every validated release-readiness finding, preserve trusted self-hosted/LAN integrations, and merge one fully reviewed hardening PR.

**Architecture:** Enforce each trust boundary once: Accounts reloads privileged actors, `Library.PathPolicy` owns filesystem containment, and `HTTPPolicy` owns redirect/destination/body limits. Durable download intents bridge database state to downloader-specific reconciliation keys. UI accessibility remains in the existing Phoenix components and shared LiveView hooks.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto/SQLite, Req/Finch, ExUnit/Mox/Req.Test, Tailwind/daisyUI, Docker, GitHub Actions.

## Global Constraints

- Preserve the single-instance, household-scale SQLite architecture.
- Preserve administrator-configured loopback, Docker DNS, private-network, and LAN services.
- Treat indexer/provider-returned destinations as untrusted.
- Keep every external service behind its existing behaviour and keep tests offline.
- Every writer continues through the relevant Accounts or `Catalog.transition` choke-point.
- Add no service environment variables; only boot security inputs may use runtime environment variables.
- Every behavior change begins with a failing regression and a positive compatibility control.
- End every task with focused tests, `mix format`, and a repository-native commit.

---

## File Structure

**New focused units**

- `lib/cinder/library/path_policy.ex` — lexical containment, component `lstat`, regular-file checks, bounded non-symlink traversal.
- `lib/cinder/http_policy.ex` — origin comparison, untrusted-address validation, manual redirect policy, bounded response collection, sanitization.
- `lib/cinder/download/intent.ex` — durable pending/submitted downloader operation schema.
- `priv/repo/migrations/20260712090000_create_download_intents.exs` — intent table and unique operation key.
- `lib/cinder_web/controllers/health_controller.ex` — content-free readiness response.
- Matching focused tests under `test/cinder/library/path_policy_test.exs`, `test/cinder/http_policy_test.exs`, `test/cinder/download/intent_test.exs`, and `test/cinder_web/controllers/health_controller_test.exs`.

**Existing boundaries modified**

- Accounts/session/bootstrap: `lib/cinder/accounts.ex`, `lib/cinder/accounts/login_rate_limiter.ex`, `lib/cinder_web/user_auth.ex`, `lib/cinder_web/live/users_live.ex`, `lib/cinder_web/live/user_live/registration.ex`, `config/runtime.exs`, `docker-compose.yml`.
- Library/settings: `lib/cinder/settings.ex`, `lib/cinder/library.ex`, `lib/cinder/library/filesystem.ex`, `lib/cinder/library/filesystem/disk.ex`, `lib/cinder_web/components/settings_components.ex`.
- HTTP clients: Prowlarr, qBittorrent, SABnzbd, Jellyfin, Plex, OpenSubtitles, LibreTranslate, Discord, and their existing tests.
- Durable pipeline: `lib/cinder/download.ex`, `lib/cinder/download/client.ex`, `lib/cinder/download/poller.ex`, `lib/cinder/download/tv_poller.ex`, `lib/cinder/catalog.ex`, `lib/cinder/catalog/refresher.ex`.
- UI: `lib/cinder_web/router.ex`, `lib/cinder_web/user_auth.ex`, `lib/cinder_web/components/layouts.ex`, `lib/cinder_web/components/core_components.ex`, `lib/cinder_web/components/settings_components.ex`, `lib/cinder_web/live/settings_live.ex`, translations and LiveView tests.
- Release gates: `mix.lock`, `.github/workflows/ci.yml`, `Dockerfile`, `.env.example`, `README.md`.

---

### Task 1: Patch dependencies and make release checks executable

**Files:**
- Modify: `mix.lock`
- Create: `lib/cinder_web/controllers/health_controller.ex`
- Modify: `lib/cinder_web/router.ex`
- Test: `test/cinder_web/controllers/health_controller_test.exs`
- Modify: `Dockerfile`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `GET /healthz` returning status 200 and body `ok` without session/database/configuration data.
- Produces: CI jobs `test`, `dependency-audit`, and `container`.

- [ ] **Step 1: Write the readiness regression**

```elixir
defmodule CinderWeb.HealthControllerTest do
  use CinderWeb.ConnCase, async: true

  test "GET /healthz is content-free and does not create a session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert response(conn, 200) == "ok"
    refute get_resp_header(conn, "set-cookie") != []
  end
end
```

- [ ] **Step 2: Run it and prove the route is absent**

Run: `direnv exec . mix test test/cinder_web/controllers/health_controller_test.exs`
Expected: FAIL because `/healthz` is not routed.

- [ ] **Step 3: Add the minimal readiness endpoint**

```elixir
defmodule CinderWeb.HealthController do
  use CinderWeb, :controller
  def show(conn, _params), do: text(conn, "ok")
end
```

Route it through a dedicated scope with no browser/session pipeline:

```elixir
scope "/", CinderWeb do
  get "/healthz", HealthController, :show
end
```

- [ ] **Step 4: Upgrade Plug and verify both advisories disappear**

Run: `direnv exec . mix deps.update plug`
Expected: `mix.lock` resolves Plug `>= 1.20.3` without unrelated major upgrades.

Run: `direnv exec . mix hex.audit`
Expected: exit 0, no advisories.

- [ ] **Step 5: Add container and CI gates**

Add `curl` to the final image's existing `apt-get install` line and add:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["/bin/sh", "-c", "curl --fail --silent --show-error http://127.0.0.1:${PORT:-4000}/healthz >/dev/null"]
```

Add CI steps/jobs that run `mix hex.audit`, `docker build --check .`, build the production image,
and scan it with the official Trivy action using `severity: HIGH,CRITICAL`, `ignore-unfixed: true`,
and `exit-code: 1`.

- [ ] **Step 6: Verify and commit**

Run: `direnv exec . mix test test/cinder_web/controllers/health_controller_test.exs`
Run: `SECRET_KEY_BASE=test-only docker compose config --quiet`
Run: `docker build --check .`
Run: `docker build -t cinder:release-hardening .`
Expected: all pass and the built image reports a health check.

Commit: `fix: patch Plug and add release security gates`

---

### Task 2: Enforce current authorization, session revocation, bootstrap, and atomic throttling

**Files:**
- Modify: `lib/cinder/accounts.ex`
- Modify: `lib/cinder/accounts/login_rate_limiter.ex`
- Modify: `lib/cinder_web/user_auth.ex`
- Modify: `lib/cinder_web/live/users_live.ex`
- Modify: `lib/cinder_web/live/user_live/registration.ex`
- Modify: `config/config.exs`, `config/runtime.exs`, `config/test.exs`
- Modify: `docker-compose.yml`, `.env.example`, `README.md`
- Test: `test/cinder/accounts_test.exs`
- Test: `test/cinder_web/live/users_live_test.exs`
- Test: `test/cinder_web/user_auth_test.exs`
- Test: `test/cinder_web/live/user_live/registration_test.exs`
- Test: `test/cinder_web/controllers/user_session_controller_test.exs`

**Interfaces:**
- Produces: `Accounts.fetch_current_admin/1 :: {:ok, User.t()} | {:error, :unauthorized}`.
- Produces: admin mutations returning `{:ok, value, revoked_tokens}` where revocation is required.
- Produces: `Accounts.replace_user_session_token/2 :: {:ok, new_token, old_tokens}` in one transaction.
- Produces: `UserAuth.disconnect_sessions/1` called only after the revoking transaction commits.

- [ ] **Step 1: Add failing stale-admin and revocation regressions**

Use a mounted `/users` LiveView, demote its actor directly through a second admin, then send each
privileged event. Assert no user, role, quota, email, password, or deletion mutation occurs and the
socket redirects or returns an authorization flash. Add separate tests proving role change,
password reset, and deletion broadcast `disconnect` to every returned token topic.

Representative context assertion:

```elixir
assert {:error, :unauthorized} = Accounts.update_user_role(stale_admin, target, :admin)
assert Accounts.get_user!(target.id).role == :user
```

- [ ] **Step 2: Prove the stale actor currently succeeds**

Run: `direnv exec . mix test test/cinder/accounts_test.exs test/cinder_web/live/users_live_test.exs`
Expected: new stale-actor assertions FAIL.

- [ ] **Step 3: Reload and authorize the actor at the writer boundary**

Implement:

```elixir
def fetch_current_admin(%User{id: id}) do
  case Repo.get(User, id) do
    %User{role: :admin} = actor -> {:ok, actor}
    _ -> {:error, :unauthorized}
  end
end
```

Every Accounts admin mutation calls this inside its transaction before touching the target. Do not
rely on `socket.assigns.current_scope.user.role`. Preserve existing target constraints such as the
last-admin rule.

- [ ] **Step 4: Make token replacement and revocation atomic**

Inside one `Repo.transaction`, insert the new session token, delete the superseded token, and return
both. Update `maybe_reissue_user_session_token/3` to install the new token and disconnect the old
topic after commit. Update admin password reset, role change, and deletion flows to return affected
tokens, then call `UserAuth.disconnect_sessions/1` from the web layer.

Add a regression that the old token returns `nil` immediately after reissue while the new token
authenticates normally.

- [ ] **Step 5: Require the one-time bootstrap token fail-closed**

Load `CINDER_BOOTSTRAP_TOKEN` into `config :cinder, :bootstrap_token` at runtime without logging it.
When `Accounts.list_users()` is empty, registration must require a constant-time match:

```elixir
def valid_bootstrap_token?(submitted) when is_binary(submitted) do
  expected = Application.get_env(:cinder, :bootstrap_token)
  is_binary(expected) and byte_size(expected) == byte_size(submitted) and
    Plug.Crypto.secure_compare(expected, submitted)
end
def valid_bootstrap_token?(_), do: false
```

If no token is configured, first registration is unavailable rather than open. Once a user exists,
the field disappears and later registrations keep their existing user role. Require the variable
in Compose quickstart and document removing it after claim.

- [ ] **Step 6: Replace the limiter race with an atomic ETS operation**

Use `:ets.update_counter/4` with a default tuple for increments in the active window. Reset expired
windows with `:ets.select_replace/2` or a serialized GenServer call; no read-then-insert increment
may remain. Add a 100-task `Task.async_stream` regression asserting the stored count is exactly 100
and `blocked?/2` is true.

- [ ] **Step 7: Set production cookies Secure without breaking HTTP tests**

Move remember-me options into a function and append
`secure: Application.get_env(:cinder, :secure_cookies, false)`. Set `secure_cookies: true` in prod
runtime and false in dev/test. Assert `Secure` is present in a production-configured response and
remember-me login still works in normal ConnCase tests.

- [ ] **Step 8: Verify and commit**

Run: `direnv exec . mix test test/cinder/accounts_test.exs test/cinder_web/user_auth_test.exs test/cinder_web/live/users_live_test.exs test/cinder_web/live/user_live/registration_test.exs test/cinder_web/controllers/user_session_controller_test.exs`
Expected: all pass, including stale-socket and concurrency regressions.

Commit: `fix: enforce live authorization and session revocation`

---

### Task 3: Establish safe download and library filesystem boundaries

**Files:**
- Create: `lib/cinder/library/path_policy.ex`
- Create: `test/cinder/library/path_policy_test.exs`
- Modify: `lib/cinder/settings.ex`
- Modify: `lib/cinder/library/filesystem.ex`
- Modify: `lib/cinder/library/filesystem/disk.ex`
- Modify: `lib/cinder/library.ex`
- Modify: `lib/cinder_web/components/settings_components.ex`
- Test: `test/cinder/settings_test.exs`
- Test: `test/cinder/library/filesystem/disk_test.exs`
- Test: `test/cinder/library_test.exs`
- Test: `test/cinder_web/live/settings_live_test.exs`

**Interfaces:**
- Produces: `Settings.import_roots/0 :: [String.t()]` from newline/comma-separated Settings input.
- Produces: `PathPolicy.source_file(path, roots, extensions) :: {:ok, expanded} | {:error, :unsafe_source}`.
- Produces: `PathPolicy.destination(path, root) :: {:ok, expanded} | {:error, :unsafe_destination}`.
- Produces: `PathPolicy.walk(root, opts) :: {:ok, [{path, size}]} | {:error, reason}`.
- Produces: `PathPolicy.deletable_file(path, roots) :: :ok | {:error, :unsafe_delete}`.

- [ ] **Step 1: Encode every demonstrated escape as a failing test**

Create real temporary trees for: a source-file symlink to the database, a directory symlink outside
the root, two cyclic directory symlinks, a sibling-prefix path, a symlinked destination parent, and
an out-of-root delete. Include positive regular-file, nested-directory, existing-hardlink, and EXDEV
copy controls.

```elixir
assert {:error, :unsafe_source} = PathPolicy.source_file(link, [download_root], [".mkv"])
assert {:error, :unsafe_destination} = PathPolicy.destination(escaped_dest, movie_root)
assert {:error, :unsafe_delete} = PathPolicy.deletable_file(db_path, [movie_root, tv_root])
```

- [ ] **Step 2: Run the new policy tests and prove the module is absent**

Run: `direnv exec . mix test test/cinder/library/path_policy_test.exs`
Expected: FAIL because `Cinder.Library.PathPolicy` does not exist.

- [ ] **Step 3: Implement component-by-component `lstat` validation**

Use `Path.expand/1` plus a boundary-safe containment predicate:

```elixir
def contained?(path, root) do
  path = Path.expand(path)
  root = Path.expand(root)
  path == root or String.starts_with?(path, root <> "/")
end
```

Walk every existing component with `lstat`; reject `type: :symlink`. Require the leaf source to be
`:regular` and an allowlisted extension. The recursive walker must use `File.ls/1` + `lstat`, skip
symlinks, track `{major_device, inode}`, and return `:traversal_limit` after 64 levels or 100,000
entries. Add the needed `ls/1` callback to the Filesystem behaviour and mock.

- [ ] **Step 4: Add and validate import-root Settings**

Add non-secret key `import_roots` to the library group. Parse newline/comma-separated values,
normalize with `Path.expand`, remove duplicates, and reject `/`. If unset, infer the common parent
of movie/TV roots only when it is neither `/` nor either library leaf; otherwise return `[]` and
hold imports as `:download_roots_not_configured`.

- [ ] **Step 5: Apply the policy before every sink**

Validate movie and episode sources before `lstat`, traversal, hardlink, or copy. Validate destination
parents before `mkdir_p`, temp creation, hardlink/copy, rename, and replacement. Change
`Library.delete_file/1` to validate against library roots before `rm`; remove the old test that
expected outside-root unlinking and replace it with a rejection assertion.

Return stable sanitized errors. Keep regular imports, idempotent identical hardlinks, sidecars,
cross-device copy, and stale-temp cleanup working inside the validated boundary.

- [ ] **Step 6: Verify exploit closure and compatibility**

Run: `direnv exec . mix test test/cinder/library/path_policy_test.exs test/cinder/library/filesystem/disk_test.exs test/cinder/library_test.exs test/cinder/settings_test.exs test/cinder_web/live/settings_live_test.exs`
Expected: all escape/cycle tests pass and all existing import controls remain green.

Commit: `fix: contain library filesystem operations`

---

### Task 4: Build the shared outbound HTTP policy

**Files:**
- Create: `lib/cinder/http_policy.ex`
- Create: `test/cinder/http_policy_test.exs`

**Interfaces:**
- Produces: `HTTPPolicy.same_origin?/2` comparing normalized scheme, host, and effective port.
- Produces: `HTTPPolicy.validate_untrusted_url/2` with injectable resolver for tests.
- Produces: `HTTPPolicy.resolve_redirect/3` enforcing origin/scheme/destination rules.
- Produces: `HTTPPolicy.bounded_request/2` returning `{:ok, Req.Response.t()} | {:error, term()}`.
- Produces: `HTTPPolicy.sanitize_log/1` removing CR/LF and bounding remote strings.

- [ ] **Step 1: Write table-driven policy regressions**

Cover IPv4 and IPv6 loopback, RFC1918/ULA, link-local, multicast, unspecified, reserved addresses,
decimal/hex textual forms accepted by `:inet`, DNS resolving to mixed public/private addresses,
relative same-origin redirects, cross-origin redirects, HTTPS downgrade, userinfo, and public HTTPS.
Inject the resolver so tests remain offline.

- [ ] **Step 2: Prove the tests fail before implementation**

Run: `direnv exec . mix test test/cinder/http_policy_test.exs`
Expected: FAIL because the module is absent.

- [ ] **Step 3: Implement strict URI/origin/address validation**

Reject userinfo, fragments where unsupported, non-HTTP(S) schemes, missing hosts, and any resolution
containing a forbidden address. Normalize default ports before origin comparison. Re-resolve every
redirect destination. Keep configured-origin calls separate from untrusted destinations.

- [ ] **Step 4: Implement bounded streaming collection**

Use Req's `into` callback with `decode_body: false`:

```elixir
into = fn {:data, chunk}, {req, resp} ->
  body = resp.body <> chunk
  if byte_size(body) > max_bytes do
    {:halt, {req, %{resp | body: {:error, :response_too_large}}}}
  else
    {:cont, {req, %{resp | body: body}}}
  end
end
```

Return `{:error, :response_too_large}` for the sentinel, manually decode JSON only after the bounded
body completes, and preserve Req/Test injection options.

- [ ] **Step 5: Verify and commit**

Run: `direnv exec . mix test test/cinder/http_policy_test.exs`
Run: `direnv exec . mix test`
Expected: policy tests and the unchanged repository suite pass.

Commit: `feat: add outbound HTTP security policy`

---

### Task 5: Apply redirect, SSRF, credential, and body limits to every HTTP client

**Files:**
- Modify and test: `lib/cinder/acquisition/indexer/prowlarr.ex`, `test/cinder/acquisition/indexer/prowlarr_test.exs`
- Modify and test: `lib/cinder/catalog/tmdb/http.ex`, `test/cinder/catalog/tmdb/http_test.exs`
- Modify and test: `lib/cinder/download/client/qbittorrent.ex`, `test/cinder/download/client/qbittorrent_test.exs`
- Modify and test: `lib/cinder/download/client/sabnzbd.ex`, `test/cinder/download/client/sabnzbd_test.exs`
- Modify and test: `lib/cinder/subtitles/provider/open_subtitles.ex`, `test/cinder/subtitles/provider/open_subtitles_test.exs`
- Modify and test: `lib/cinder/subtitles/translator/libre_translate.ex`, `test/cinder/subtitles/translator/libre_translate_test.exs`
- Modify and test: `lib/cinder/notifier/discord.ex`, `test/cinder/notifier/discord_test.exs`
- Modify and test: `lib/cinder/library/media_server/jellyfin.ex`, `test/cinder/library/media_server/jellyfin_test.exs`
- Modify and test: `lib/cinder/library/media_server/plex.ex`, `test/cinder/library/media_server/plex_test.exs`

**Interfaces:**
- Consumes: all `Cinder.HTTPPolicy` functions from Task 4.
- Preserves: existing behaviours and public return tuples.

- [ ] **Step 1: Add realistic redirect and oversized-body regressions per client**

For every credential-bearing request, use `Req.Test` to return each redirect class. Assert 307/308
never forwards form/JSON bodies, custom API-key headers, manually supplied Cookie headers, or
subtitle content to another host. Assert same-origin redirects work only where required. Assert
oversized torrent/subtitle/translation/JSON bodies return the client's existing error style.

- [ ] **Step 2: Run focused client tests and capture the vulnerable behavior**

Run all nine test files listed above.
Expected: new cross-origin and size assertions FAIL on the current clients.

- [ ] **Step 3: Disable automatic redirects and use the correct trust class**

Configured LAN clients use configured-origin requests with `redirect: false`; manually follow only
same-origin, no-downgrade locations. qBittorrent torrent URLs and OpenSubtitles returned download
links call `validate_untrusted_url/2` before the first request and every redirect. SABnzbd `addurl`
rejects unsafe provider URLs before delegating the fetch.

Use conservative limits documented as module attributes: 10 MiB torrents, 10 MiB subtitles,
4 MiB JSON/API responses, 8 MiB translation request/response batches, five redirects, existing
connect timeouts, and a bounded total request deadline.

- [ ] **Step 4: Protect protocol-specific secrets**

Never forward `x-api-key`, `x-emby-token`, `x-plex-token`, `api-key`, qBittorrent SID cookies, login
forms, Discord embeds, or LibreTranslate JSON cross-origin. Keep SABnzbd's required `apikey` query
parameter but ensure no URL is logged. Add header authentication only if an existing supported
SABnzbd API test proves it; otherwise retain query compatibility and document the residual.

- [ ] **Step 5: Sanitize remote log fields**

Pass release titles, content paths, and remote reasons through `HTTPPolicy.sanitize_log/1` or log
them as structured metadata. Add CR/LF-forging tests for TV poller messages and client failures.

- [ ] **Step 6: Verify and commit**

Run: `direnv exec . mix test test/cinder/acquisition/indexer/prowlarr_test.exs test/cinder/catalog/tmdb/http_test.exs test/cinder/download/client/qbittorrent_test.exs test/cinder/download/client/sabnzbd_test.exs test/cinder/subtitles/provider/open_subtitles_test.exs test/cinder/subtitles/translator/libre_translate_test.exs test/cinder/notifier/discord_test.exs test/cinder/library/media_server/jellyfin_test.exs test/cinder/library/media_server/plex_test.exs`
Expected: all policy, redirect, size, and compatibility controls pass.

Commit: `fix: harden outbound service requests`

---

### Task 6: Make external download submission durable and reconcilable

**Files:**
- Create: `lib/cinder/download/intent.ex`
- Create: `priv/repo/migrations/20260712090000_create_download_intents.exs`
- Create: `test/cinder/download/intent_test.exs`
- Modify: `lib/cinder/download/client.ex`
- Modify: `lib/cinder/download.ex`
- Modify: `lib/cinder/download/poller.ex`
- Modify: `lib/cinder/download/tv_poller.ex`
- Modify: qBittorrent/SABnzbd clients and tests
- Modify: `test/support/mocks.ex`
- Test: `test/cinder/download/poller_test.exs`, `test/cinder/download/tv_poller_test.exs`

**Interfaces:**
- Produces: `Client.add(release, operation_key: key)` and `Client.find_by_operation_key(key)`.
- Produces: `Download.reserve_intent/1`, `Download.submit_intent/1`, `Download.reconcile_intent/1`.
- Intent fields: `operation_key`, `kind`, `target_id`, `episode_ids`, `protocol`, `release`, `status`, `remote_id`, timestamps.

- [ ] **Step 1: Write crash-window regressions**

Inject a client that accepts `add/2` and then kills the calling process before Cinder stores the
remote ID. Restart the poller and assert it calls `find_by_operation_key/1`, records the existing
job, and never calls `add/2` a second time. Cover movie, single episode, and season pack.

- [ ] **Step 2: Add the intent schema and uniqueness constraints**

Create `download_intents` with a unique `operation_key`, indexed status, JSON release payload and
episode IDs, nullable `remote_id`, and Ecto enum `:reserved | :submitted`. Use UUID-like random
operation keys generated once by Cinder, never external input.

- [ ] **Step 3: Extend the behaviour and downloader reconciliation**

qBittorrent adds tag `cinder-<operation_key>` and finds jobs with `/torrents/info?tag=...`.
SABnzbd sets `nzbname=cinder-<operation_key>` and searches queue then history for that exact name,
returning its `nzo_id`. Preserve infohash/nzo-id as the normal Cinder download ID.

- [ ] **Step 4: Reserve before side effects and reconcile before retry**

Persist the chosen release and targets before `client.add/2`. On every pending intent, first call
`find_by_operation_key/1`; submit only on `:not_found`. Attach the remote ID and advance the movie
or create/link the grab through existing guarded Catalog writes. Delete/complete the intent only
after the domain row owns the remote ID. Cancellation removes both the remote job and intent.

- [ ] **Step 5: Verify process-death recovery**

Run: `direnv exec . mix test test/cinder/download/intent_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs`
Expected: no duplicate `add` after any injected process-death boundary; normal adds remain one call.

Commit: `fix: make downloader submission idempotent`

---

### Task 7: Close import, upgrade, cancellation, and refresh races

**Files:**
- Modify: `lib/cinder/library.ex`
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/download/poller.ex`
- Modify: `lib/cinder/download/tv_poller.ex`
- Modify: `lib/cinder/catalog/refresher.ex`
- Test: `test/cinder/library_test.exs`
- Test: `test/cinder/download/poller_test.exs`
- Test: `test/cinder/download/tv_poller_test.exs`
- Test: `test/cinder/catalog/refresher_test.exs`

**Interfaces:**
- Produces: staged library result `%{dest: path, rollback: token, quality: map}`.
- Produces: `Library.commit_stage/1` and `Library.rollback_stage/1`, both idempotent.
- Tightens: `Catalog.finish_grab/2` updates only episodes still owned by the supplied grab.

- [ ] **Step 1: Add race and rollback regressions**

Pause the test filesystem after staging, concurrently cancel/delete the movie or grab, resume, and
assert the staged destination is removed and no row receives it. For same-path upgrades, force the
Catalog CAS to return stale and assert original bytes are restored. Cancel a series, run Refresher
with a newly announced season, and assert it remains unmonitored.

- [ ] **Step 2: Stage replacements with rollback material**

Never overwrite the live path before the guarded database transition. Write the candidate to a
unique sibling temp path. For same-path replacement, rename the live file to a rollback path, move
the candidate into place, run the Catalog transition, then delete rollback only after commit. On
stale/error, restore rollback and remove candidate. All operations remain inside `PathPolicy`.

- [ ] **Step 3: Guard TV finalization by current grab ownership**

Change each imported episode update predicate to
`where: e.id == ^episode_id and e.grab_id == ^grab.id and e.monitored == true`. If any imported
episode no longer matches, roll back the DB transaction and return `{:error, :stale_grab}` so the
poller removes staged destinations. Delete the grab without `allow_stale` inside this finalization.

- [ ] **Step 4: Persist series cancellation policy**

Update the series row itself to `monitored: false` and its none/off monitoring strategy in the same
transaction that unmonitors seasons/episodes. Refresher reloads the current series policy before
inserting or monitoring newly announced seasons.

- [ ] **Step 5: Verify and commit**

Run: `direnv exec . mix test test/cinder/library_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder/catalog/refresher_test.exs`
Expected: injected cancellation/process-death paths restore or remove files; ordinary imports and
upgrades still complete.

Commit: `fix: make imports and cancellation race-safe`

---

### Task 8: Finish accessibility and responsive Settings polish

**Files:**
- Modify: `lib/cinder_web/user_auth.ex`
- Modify: `lib/cinder_web/components/layouts.ex`
- Modify: `lib/cinder_web/components/core_components.ex`
- Modify: `lib/cinder_web/components/settings_components.ex`
- Modify: `lib/cinder_web/live/settings_live.ex`
- Modify: `priv/gettext/default.pot`, English/French catalogs
- Test: `test/cinder_web/user_auth_test.exs`
- Test: `test/cinder_web/live/settings_live_test.exs`
- Test: relevant LiveView route tests

**Interfaces:**
- Produces: `UserAuth.page_title(path) :: localized String.t()` through the existing current-path hook.
- Produces: `service_fields` disclosure state keyed by stable Settings group names.

- [ ] **Step 1: Add semantic and title regressions**

For every routed LiveView, assert `<title>` is not `Cinder · Cinder` and contains the localized route
name. Assert exactly one labelled navigation landmark. Assert Settings uses native `<details>` /
`<summary>` or buttons with `aria-expanded` and stable region IDs. Component tests assert compact
buttons and flash dismiss controls include at least `min-h-6 min-w-6`; primary mobile controls use
`min-h-11`.

- [ ] **Step 2: Extend the current-path hook to assign titles**

Map stable routes to gettext strings in one helper; handle dynamic movie/series routes by their
section title. In the hook assign both `current_path` and `page_title`, so no LiveView duplicates
title logic. Cover login, registration, account, setup, requester, and admin sessions.

- [ ] **Step 3: Add navigation landmark and target sizing**

Wrap the sidebar menu in `<nav aria-label={gettext("Primary")}>`. Keep the outer `aside` for layout.
Raise global small-button minimum dimensions without forcing all controls to 44px; explicitly give
mobile primary actions, locale buttons, flash dismiss, and Settings test controls sufficient target
size and spacing.

- [ ] **Step 4: Convert Settings groups to accessible disclosures**

Render each group inside a keyboard-native disclosure, open the first/incomplete/error-containing
group by default, and preserve all input names inside the single form. Do not introduce per-section
saves or duplicate state. Ensure health badges and test actions remain associated with their group.

- [ ] **Step 5: Verify UI behavior and commit**

Run: `direnv exec . mix test test/cinder_web/user_auth_test.exs test/cinder_web/live/settings_live_test.exs test/cinder_web/live`
Run the Playwright audit at 1440×900 and 390×844 for admin/requester, dark/light, EN/FR, and reduced
motion. Assert no console errors, page errors, horizontal overflow, contrast failure, missing title,
or undersized essential target.

Commit: `fix: complete responsive accessibility polish`

---

### Task 9: Quiet expected test failures and execute the complete release gate

**Files:**
- Modify only tests that intentionally emit expected warning/error logs.
- Modify: `graphify-out/graph.json` and derived graph artifacts through `graphify update .` only.

**Interfaces:**
- Produces: a full test run where expected failure logs are captured locally and unexpected logs
  remain visible.

- [ ] **Step 1: Capture expected logs at their source tests**

Use `ExUnit.CaptureLog.capture_log/1` around explicit failure-path triggers. Assert on the message
when it is part of behavior; otherwise only capture it. Do not lower the global test logger level.

- [ ] **Step 2: Run every repository and release verification gate**

Run, in order:

```bash
direnv exec . mix test
direnv exec . mix test --repeat-until-failure 3 --max-failures 1
direnv exec . mix deps.unlock --check-unused
direnv exec . mix hex.audit
graphify update .
SECRET_KEY_BASE=audit-only-not-a-real-secret docker compose config --quiet
docker build --check .
docker build -t cinder:release-hardening .
nix shell nixpkgs#trivy -c trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 cinder:release-hardening
```

Expected: all commands exit 0; every test run passes; Hex reports no advisory; Trivy reports no
fixed HIGH/CRITICAL image vulnerability.

- [ ] **Step 3: Run the final browser matrix**

Use an isolated temporary SQLite database and two fixture accounts. Cover anonymous login/register,
requester Discover/My Requests and admin Dashboard/Requests/Library/Activity/Calendar/Settings/Users
at desktop/mobile, both themes, both locales, keyboard navigation, drawer operation, reduced motion,
titles, landmarks, target sizes, and authorization redirects. Stop the server and remove the temp DB.

- [ ] **Step 4: Review the complete diff and commit remaining test-only cleanup**

Run: `git diff origin/main...HEAD --check`
Run: `git status --short`
Run targeted security bypass review for sibling sinks and a simplicity/over-engineering review.

Commit only if test-log or graph artifacts changed: `test: complete release hardening verification`

---

### Task 10: Open, review, repair, and merge the pull request

**Files:**
- No source files unless review identifies a reproducible defect.

**Interfaces:**
- Produces: one GitHub PR from `agent/release-hardening` to `main`, all checks green, all actionable
  review findings fixed, squash-merged.

- [ ] **Step 1: Rebase on current main and publish**

```bash
git fetch origin
git rebase origin/main
git push -u origin agent/release-hardening
```

Re-run `mix test` if the rebase changes any application or dependency file.

- [ ] **Step 2: Open the PR with verification evidence**

Use `gh pr create` with a body covering the threat boundaries, compatibility policy, schema/config
changes, exact verification commands, UI matrix, and remaining DNS rebinding limitation if the
transport could not pin the vetted address.

- [ ] **Step 3: Perform two review passes**

First request a security/code review focused on bypasses, data loss, migrations, concurrency, and
compatibility. Then request UI/accessibility review focused on titles, semantics, targets, keyboard,
themes, locales, and mobile layout. Inspect GitHub checks and every review thread.

- [ ] **Step 4: Fix every actionable finding with TDD**

For each finding: reproduce with a failing focused test, implement the narrowest correction, rerun
the focused owner suite and `mix test`, commit, push, and resolve the thread. Do not dismiss a
finding solely because it is inconvenient or outside the original implementation rationale.

- [ ] **Step 5: Wait for green CI and squash-merge**

Use `gh pr checks --watch`. When all required checks pass and review threads are resolved, run
`gh pr merge --squash --delete-branch`. Fetch `main`, confirm the merged commit is reachable from
`origin/main`, and verify the local worktree is clean.
