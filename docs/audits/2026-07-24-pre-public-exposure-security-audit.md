# Pre-public-exposure security audit — Cinder

**Date:** 2026-07-24
**Commit reviewed:** `3fd7e00`
**Trigger:** operator is about to expose Cinder to the public internet via a Cloudflare Tunnel
(cloudflared) — the login *and* registration pages become reachable by anyone, with no VPN in front.
**Method:** two independent audits, cross-checked.
- A 7-dimension multi-agent workflow (Sonnet finders → Fable adversarial verifiers): 16 candidate
  findings, 9 survived verification, 7 refuted on reading framework/config code.
- An independent deep pass by Codex/**sol** (`gpt-5.6-sol`, xhigh) on the crown-jewel surface
  (registration/privilege, session/cookie, authz/IDOR, SSRF/injection/filesystem).

Both passes agree closely. Where they diverge it is on *severity framing*, not facts.

## Threat model

Attacker is an **anonymous internet user** who found the URL, or a **low-privilege `:user`** (a
friend, or a stranger who self-registered). TLS terminates at Cloudflare; the origin trusts
`X-Forwarded-Proto`. The optional `CINDER_BASIC_AUTH_*` gate is assumed **unset** (friends log in via
the app's own pages). So the app's own auth is the entire public perimeter.

---

## Executive verdict

The codebase is genuinely security-conscious and holds up well: **no critical vulnerability, no path
from public registration to `:admin`, no user→admin IDOR, the approval gate holds in the data model,
and the production session cookie is correctly `Secure`.** No command injection, SQL injection, or
path traversal was found.

The real risk is entirely structural: **Cinder was built for a "Caddy + VPN edge" and leaned on that
outer gate. Cloudflared removes it.** Two things weren't built to be the sole perimeter — open
registration, and rate-limiting that silently breaks once every client shares the tunnel's IP.

**Do not expose with both public registration and `auto_approve_all` enabled.** Fix Tier 1 first.

| # | Severity | Finding | Reachable by |
|---|----------|---------|--------------|
| 1 | **High** (w/ `auto_approve_all`) / Medium (default) | Unrestricted, auto-confirmed self-registration + unlimited default quota | anonymous |
| 2 | **Medium** | Rate-limiting collapses behind the tunnel → targeted login lockout + unthrottled bcrypt DoS | anonymous |
| 3 | Medium | SSRF controls stop before the actual connection / downstream downloaders | supply-chain (indexer/torrent), not web-facing |
| 4 | Low | Plex can take the first-user slot and block admin bootstrap | operator-config |
| 5 | Low | Missing Content-Security-Policy (`script-src`/`default-src`) | defense-in-depth (no XSS sink today) |
| 6 | Low | Sudo-mode windows inconsistent (10 vs 20 min); one crashing recheck; `unlink_plex` unchecked | user |
| 7 | Low | Registration leaks account existence ("email already taken") | anonymous |

---

## Tier 1 — fix before you flip the switch

### 1. Open registration makes the `:user` role publicly obtainable

`/users/register` (`router.ex:148`) is anonymous-reachable. `Accounts.register_user/2`
(`accounts.ex:46`) gates **only the first user** behind `CINDER_BOOTSTRAP_TOKEN`; every subsequent
registration unconditionally assigns `:user`, **auto-confirms the email** (no mailbox round-trip), and
logs in — in one request. There is no invite code, allowlist, CAPTCHA, or rate limit
(`registration_test.exs:82` tests that registration is *permanently open* by design). New users get
`request_quota: nil` = **unlimited** (`user.ex:12`, `requests.ex:90`).

Impact under **default** config (`auto_approve_all` off): the download pipeline is still protected by
the admin approval gate, but a stranger can create unlimited accounts + DB rows, spend bcrypt CPU,
burn your shared TMDB key, create unbounded pending requests, squat a friend's email before they
register, and flood the admin queue.

Impact with **`auto_approve_all` on** (the "trusted household" toggle — plausible for a friends
deployment): a stranger's request bypasses the approval gate *and* quota entirely
(`requests.ex:32`; confirmed non-obviously — the approved path skips quota, `requests_test.exs:350`)
→ the poller searches indexers and **downloads real files onto your disk/bandwidth, unattended.**
This is not privilege escalation (the account stays `:user`), but it hands the low-priv attacker role
to the entire internet.

**Fix (friends-only service):**
1. Gate account creation itself — the cleanest option is an **admin-issued invite token** (generalize
   the existing `bootstrap_token` machinery into a rotating invite code), or an `active: false` flag
   on self-registered accounts that an admin flips before `require_authenticated` lets them do
   anything, or simply **disable general registration after the first admin**.
2. Give self-registered accounts a **conservative default `request_quota`** instead of `nil`.
3. **Keep `auto_approve_all` OFF** while public enrollment is open, and add a loud inline warning on
   that setting ("also auto-approves anyone who self-registers, including strangers").
4. Move the quota check **before** the auto-approve decision so auto-approval changes *adjudication*,
   not *resource limits*.
5. Immediate edge backstop: put `/users/register` behind **Cloudflare Access** (email OTP / shared
   PIN) so only invited people reach the form at all.

### 2. Rate-limiting silently breaks behind the tunnel

There is **no `remote_ip`/trusted-proxy plug** anywhere (`mix.lock` has no `remote_ip`/`hammer`).
Behind cloudflared, `conn.remote_ip` (`user_session_controller.ex:44`) is the tunnel's loopback hop
for *every* internet visitor. Two consequences, both anonymous-reachable:

- **Targeted login-lockout DoS.** `LoginRateLimiter` keys on `{ip, email}` and is checked *before*
  password verification (`user_session_controller.ex:17`), so a blocked pair is denied even with the
  correct password. With `ip` constant, the key degrades to per-email: **10 bad POSTs lock any known
  account (including your admin) out of password login for 15 min, repeatable forever.** The module
  moduledoc already documents this as an accepted ceiling "behind the documented reverse proxy" —
  cloudflared with no VPN is exactly the condition that turns the accepted ceiling into a
  stranger-exploitable weapon. (A Plex-linked account keeps the `/auth/plex` path; existing sessions
  are unaffected.)
- **Unthrottled bcrypt CPU-exhaustion DoS.** Registration has **no limiter at all**; each fresh-email
  submission runs a cost-12 `Bcrypt.hash_pwd_salt`. Login runs `Bcrypt.verify_pass`/`no_user_verify`
  on every non-blocked attempt, and rotating a random email per request evades the `{ip,email}`
  limiter. Single BEAM instance (SQLite, no horizontal scaling) → saturating schedulers denies the
  app to the whole household.

**Fix:**
1. Add a **`RemoteIp` plug** (hex `remote_ip`) wired before `CinderWeb.Router` in `endpoint.ex`,
   configured with `headers: ~w[cf-connecting-ip]`. Note the trust boundary carefully: `remote_ip`
   auto-trusts reserved/private-range peers, and the cloudflared peer is loopback **only** when it
   shares the host's network — in the recommended containerized setup it's a **Docker-network
   address** (e.g. `172.x`), not `127.0.0.1`. So do **not** hand-roll a "trust the header only when
   the peer is loopback" check (it silently fails behind a containerized connector); trust the
   cloudflared peer's actual address. `CF-Connecting-IP` carries a single client IP (not an
   `X-Forwarded-For` chain), and this is safe **only because nothing but cloudflared can reach the
   origin port** (see the deployment dependency below) — that network isolation, not the peer being
   loopback, is what makes the header trustworthy. This restores per-client keying for the existing
   limiter and any future one.
2. Add an **IP-based rate limit on `/users/register`** (reuse the ETS `LoginRateLimiter` pattern,
   keyed on IP alone, ~5–10/min) and ideally a global one on `POST /users/log-in`.
3. **Immediate compensating control (do this today, before any code):** add **Cloudflare Rate
   Limiting rules** plus a **Managed Challenge** WAF custom rule for `/users/register` and
   `/users/log-in` — both are edge-only and need no app change — and/or Bot Fight Mode. (Cloudflare
   **Turnstile** is stronger but is *not* an edge toggle: it requires embedding the widget in the
   forms and verifying the token server-side via the siteverify API, i.e. app code Cinder does not
   have — treat it as a follow-up, not a launch-day control.) This is the only backstop until the
   app-level fixes land.

---

## Tier 2 — strongly recommended

### 3. SSRF: guards stop before the actual connection and downstream fetchers

Cinder already has a **strong** shared SSRF guard (`Cinder.HTTPPolicy`): it rejects
private/loopback/link-local/special-use IPv4+IPv6, validates every redirect, rejects
credentials/fragments, and blocks HTTPS downgrades. Literal `localhost` / `169.254.169.254` and
ordinary redirects are already blocked. Three residual gaps remain (the moduledoc admits the first):

- **DNS-rebinding / TOCTOU** — validation resolves the host (`http_policy.ex:27`) but Req/Finch
  resolves *again* at connect time; no IP pinning. Affects subtitle downloads
  (`open_subtitles.ex:213`) and cross-origin torrent fetch (`qbittorrent.ex:165`).
- **SABnzbd `addurl` deputy** — Cinder validates the initial URL then tells SABnzbd to fetch it
  (`sabnzbd.ex:54`); SAB does its own DNS + redirects outside `HTTPPolicy` (documented, `sabnzbd.ex:28`).
- **Embedded torrent endpoints** (sol's addition, not caught by the workflow) — the whole magnet goes
  to qBittorrent (`qbittorrent.ex:46`), and downloaded `.torrent` files are checked only for a valid
  `info`/infohash (`torrent.ex`) then uploaded unchanged. Tracker / `url-list` / `httpseeds` URLs are
  never run through `HTTPPolicy`.

Reachability is the reason severity splits (workflow: low/defense-in-depth; sol: medium, "high on a
flat network with unauthenticated control-plane services"). These are **supply-chain vectors** — the
target hostname comes from a malicious indexer/torrent result, not from a request an anonymous/`:user`
attacker sends to Cinder — so public exposure via cloudflared doesn't widen them. But they're real on
a homelab LAN, and the SSRF would be blind but pointed at your other self-hosted admin surfaces.

**Fix (in priority order):**
1. **Egress ACLs / network isolation** for Cinder + Prowlarr + SABnzbd + qBittorrent — deny loopback,
   RFC1918, link-local, and cloud-metadata destinations except the specific service addresses they
   need. This is the highest-leverage mitigation and closes all three at the network layer.
2. Pin the outbound connection to the vetted resolved IP (keep the hostname for `Host`/SNI), re-check
   after each redirect — in `HTTPPolicy.bounded_request/3` so all callers inherit it.
3. Migrate SABnzbd `addurl` → `addfile` (fetch bounded NZB bytes via `HTTPPolicy`, upload to SAB).
4. Inspect magnet params and torrent `announce`/`announce-list`/`url-list`/`httpseeds` before handing
   them to qBittorrent.

### 4. Plex can occupy the first-user slot and block admin bootstrap

`register_user/2` decides "first user" by **total user count** (`accounts.ex:46`), but Plex sign-in
(`login_or_register_plex_user`, `accounts.ex:68`/`116`) is **ungated by the bootstrap token and always
inserts `:user`**. If Plex is configured and the origin is reachable before you bootstrap, a friend
signs in with Plex → becomes the first row as `:user` → your later bootstrap-token registration sees a
non-empty table and also creates a `:user` → **no admin exists, requiring DB repair.** It cannot mint
an admin, and Plex email collision cannot take over an account — this is an availability/lockout
footgun, not escalation. Mitigated by completing bootstrap before exposure and the localhost compose
binding.

**Fix:** determine bootstrap status with `count_admins() == 0` (inside the immediate transaction), not
total user count; refuse *new* Plex-account creation until an admin exists (linked Plex users still
log in); add a regression test ("Plex user exists, zero admins → bootstrap token still creates the
admin"). **Operationally: create your admin before making the tunnel/Plex publicly reachable.**

---

## Tier 3 — hardening / defense-in-depth

### 5. No Content-Security-Policy
`put_secure_browser_headers` (`router.ex:13`) only emits Phoenix's default
`base-uri 'self'; frame-ancestors 'self'`. **No XSS sink exists today** (no `raw/1`, `{:safe}`,
`innerHTML`; all external metadata renders through auto-escaping HEEx), so this is not currently
exploitable — but it's the highest-leverage header to add before opening to strangers, so a future
`raw()` or dependency bug is contained. Add `default-src 'self'; object-src 'none';
script-src 'self' 'nonce-<per-request>'; img-src 'self' https://image.tmdb.org data:;
connect-src 'self' wss: ws:; style-src 'self' 'unsafe-inline'`. Requires a per-request nonce on the
inline theme-toggle script in `root.html.heex`.

### 6. Session cookie: make `Secure` explicit
The production session cookie **does** get `Secure` today — `force_ssl` (`prod.exs`) rewrites the
scheme from `X-Forwarded-Proto` before `plug :session`, and `Plug.Conn.put_resp_cookie/4` defaults
`secure: true` when `conn.scheme == :https` (both audits independently verified this; the two
"missing Secure flag" findings were **refuted**). Still worth adding
`secure: Application.get_env(:cinder, :secure_cookies, false)` to `Endpoint.session_options/0`
(mirroring the remember-me cookie) so it doesn't silently depend on `force_ssl` staying configured,
plus a `Set-Cookie` assertion test.

### 7. Sudo-mode windows are inconsistent (sol)
Settings mount requires auth within 10 min (`user_auth.ex:247`) but `sudo_mode?/2` defaults to 20 min
(`accounts.ex:331`); email/password event rechecks use a **crashing `true =` assertion**
(`settings.ex:141`) instead of redirecting to reauth; `unlink_plex` (`settings.ex:188`) has no
per-event sudo recheck. Not a full bypass (linking a *new* Plex identity still needs a ≤20-min
session). Fix: one sudo-window constant used everywhere; handle expiry by redirecting, not
pattern-matching `true`; add the `unlink_plex` recheck.

### 8. Registration user-enumeration
Duplicate registration returns a field-specific "has already been taken" (`registration_test.exs:111`)
with no rate limit → an anonymous wordlist learns which emails have accounts. Low (household scale, and
a miss creates a junk account rather than being clean). Fix: generic non-committal response
(`validate_unique: false`, let the DB unique constraint drive a generic message) + the register rate
limit from finding 2.

---

## Confirmed solid (independently verified by both passes — don't spend time here)

- **Privilege:** only `:user` from registration; `:role` is not castable in any changeset
  (registration/email/password/quota/Plex). Admin user-creation reloads the actor's persisted role
  inside the transaction. Password-path first-admin race is impossible (`BEGIN IMMEDIATE` serializes
  it).
- **Session/transport:** prod session cookie is `Secure` + HttpOnly + SameSite=Lax; remember-me is
  explicitly `Secure`; HSTS emitted; login renews+clears the session (fixation-safe); logout deletes
  the DB token + disconnects the socket; tokens expire (14d) and rotate (7d); role change / password
  reset revoke tokens and disconnect; token rotation preserves `authenticated_at` so a long-lived
  remember cookie can't regain sudo.
- **Authorization:** every destructive/cross-user LiveView is inside the `:admin` live_session; `/dev`
  and `/setup` require admin. `/my-requests` always re-queries by the current user's id (no IDOR);
  user request events only accept objects already loaded into that socket; forged ids in admin views
  are matched against current rows or ignored.
- **Approval gate:** a non-admin request inserts only a `:pending` row and **no movie row**;
  `find_or_create_at_requested/2` is reached only on approval or explicit `auto_approve_all`, so the
  poller has nothing to auto-consume pre-approval.
- **Filesystem/shell/SQL:** import paths are expanded, constrained to import roots, checked
  component-by-component with `lstat`, allowlisted to regular video files (`path_policy.ex`); titles
  are sanitized and release names never determine the destination path; `ffprobe`/`ffmpeg` receive
  args as list elements and the one `/bin/sh` use has a constant script with external values passed
  positionally after `--`; no runtime raw-SQL interpolation of user input.

## Also refuted (looked scary, cleared on inspection)

Missing-`Secure`-flag (×2), first-admin race (password path), bind-all-interfaces + `X-Forwarded-Proto`
spoof (cloudflared is outbound-only; no inbound port; self-defeating), `approved_by_id` mass-assignment
(gate holds regardless; mixed-key params raise `CastError`).

---

## Critical deployment dependency

The entire transport-safety conclusion (session cookie `Secure`, HSTS, `X-Forwarded-Proto` trust,
and the `CF-Connecting-IP` trust proposed in finding 2) **rests on cloudflared being the exclusive
ingress.** Cloudflare prevents ordinary clients from setting `X-Forwarded-Proto`/`CF-Connecting-IP`,
so the origin can trust them — *but only if nothing else can reach the origin port* (this is also why
the finding-2 IP trust is keyed on "the cloudflared peer can reach us and nothing else can," not on
the peer being loopback). Therefore:
- Keep the compose binding at **`127.0.0.1:4000`** — never change it to `4000:4000`.
- If cloudflared runs in a container, put both containers on an **internal Docker network**.
- A directly reachable origin would let an attacker forge those headers and defeat these assumptions.

## Launch checklist (minimum)

- [ ] Gate registration (invite/allowlist/disable-after-admin) — **finding 1**
- [ ] `auto_approve_all` OFF while registration is public — **finding 1**
- [ ] Cloudflare Rate Limiting + a **Managed Challenge** WAF custom rule on `/users/register` and `/users/log-in` (both edge-only, no app change) — **finding 2**
- [ ] `RemoteIp` plug reading `CF-Connecting-IP`, trusting the **cloudflared peer** (loopback if host-networked, the container's Docker-network address if containerized) — safe only because nothing but cloudflared reaches the origin — **finding 2**
- [ ] Create the admin account before the tunnel/Plex is publicly reachable — **finding 4**
- [ ] Confirm the origin is loopback-only (`127.0.0.1:4000`, no `4000:4000`) — **deployment dependency**
- [ ] Egress-isolate Cinder + Prowlarr + SABnzbd + qBittorrent — **finding 3**
