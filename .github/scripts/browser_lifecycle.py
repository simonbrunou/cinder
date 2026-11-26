"""Browser-level regression coverage for the two JS lifecycles assets/js/app.js gained in #592
(Kindle status-badge flare, poster-failure handling) — issue #593.

Two real bugs shipped in #592 and reached review only after `mix test` (4422 passing) and
`browser_smoke.py` both went green, because nothing in the suite touched either lifecycle:
  - Case 4 below is the actual kindle "error"-kind false-flare bug.
  - Case 5 below is the actual live-insert poster gap.
The other five of the first seven cases cover the rest of each lifecycle's real branches so a
future change to either has the same chance of being caught before review as everything else in
this app. Cases 8 to 10 cover #702: a failed poster whose card a live update re-renders, a
poster whose `src` a live update changes, and a stalled poster whose 3-second reveal must
survive a re-render. Case 11 adds a passkey and signs in with it (#1560). Case 12 drives the
indexers table's switches and Delete in /settings, and checks its width at 390 px (#1660). Case
13 drives its Add and Edit dialogs: the portal, typed values across Test finishes, the Tab trap,
Escape and the focus it returns, and a save (#1661). Case 14 submits a credential in the base URL,
the API path and the additional parameters with Enter, in the Add and the Edit dialog, and checks
that the refusal empties the focused input (#1697). Case 15 retries a refused switch to Built-in
after closing the Indexers group, which must open again with the select focused (#1662).

Driving mechanism: `docker exec <container> /app/bin/cinder rpc '<expr>'`, never `eval`. `eval`
boots a disconnected temporary node (`:nonode@nohost`) whose Catalog broadcasts can never reach
the real server's mounted LiveViews. `rpc` executes *in* the running `:cinder@<host>` node, so a
`Catalog.MovieLifecycle` verb issued this way broadcasts on the real "movies" PubSub topic and patches
the real, already-mounted `/library` page open in the browser — the same mechanism #592's author
used to hand-verify the kindle flare while writing it.

Every state-changing rpc call is bracketed by `SuspendedPoller`, which `:sys.suspend`s
`Cinder.Download.Poller` for the duration of one case's controlled writes. Without this, the
real poller (5s tick) independently sweeps every :requested/:searching movie and would race our
seeded rows with its own transitions. The bracket is scoped per case (a few seconds), not to the
whole script (25-40s), because health_controller.ex marks a poller "stale" (and /healthz 503)
after 3 missed intervals = 15s; a single long suspension would report the container unhealthy
for no reason connected to what's actually broken. Every seeded movie also carries a fake but
non-blank `imdb_id` so that if the poller ever *does* touch one (between brackets, or via a
crash mid-script), `ensure_imdb_id/1` short-circuits instead of making a real TMDB call.
"""

import base64
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

BASE_URL = os.environ.get("CINDER_SMOKE_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
EMAIL = os.environ["CINDER_SMOKE_EMAIL"]
PASSWORD = os.environ["CINDER_SMOKE_PASSWORD"]
CONTAINER = os.environ.get("CINDER_SMOKE_CONTAINER", "cinder-ci")
SCREENSHOT_DIR = os.environ.get("CINDER_SMOKE_SCREENSHOT_DIR")
# Unset in CI, which runs Playwright's bundled Chromium (#842); set it (e.g. "chrome") locally.
BROWSER_CHANNEL = os.environ.get("CINDER_SMOKE_BROWSER_CHANNEL")

# Every rpc() call gets this many seconds. 15 s failed a case whose call still landed on a
# loaded runner (#1334).
RPC_TIMEOUT = 60
# The kindle flare's own lifetime (app.js Kindle.kindle(): classList.add then a 1400ms
# setTimeout removing it). Any "prove no flare happened" wait must comfortably outlast this, or
# a real flare landing just after our check would read as a false pass.
KINDLE_FLARE_MS = 1400
SETTLE_MS = KINDLE_FLARE_MS + 600

# A tiny valid 1x1 PNG, served as the "this poster load succeeds" control response — so a poster
# case can prove the pipeline distinguishes success from failure, not just that everything ends
# up broken.
TINY_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)

RESULT_RE = re.compile(r"^RPCRESULT:(.*)$", re.MULTILINE)


class CaseFailure(AssertionError):
    """Raised with a full diagnostic — case name, expected, actual — never a bare assert."""


def _captured(output):
    # On a timeout, subprocess.run hands back the partial output as bytes, or None when the
    # stream stayed empty, even with text=True.
    if output is None:
        return ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    return output.strip()


def rpc(expr, timeout=RPC_TIMEOUT):
    """Evaluates `expr` on the running server node. `expr` must end by printing
    `RPCRESULT:<value>` — Logger/telemetry output can interleave with plain stdout across the
    docker-exec boundary, so we grep for the sentinel line instead of trusting output order.

    No caller repeats a call after a timeout (#1334). The timeout kills only the `docker`
    client: the command inside the container can still run to its end, so a repeat would run
    against state the first call may already have changed. The bound is wide instead, so a slow
    call on a loaded runner still lands."""
    started = time.monotonic()
    try:
        proc = subprocess.run(
            ["docker", "exec", CONTAINER, "/app/bin/cinder", "rpc", expr],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        raise CaseFailure(
            f"rpc call timed out after {time.monotonic() - started:.1f}s (bound {timeout}s); "
            "only the docker client was killed, so the command may still be running in the "
            "container\n"
            f"  expr: {expr}\n"
            f"  stdout: {_captured(e.stdout)}\n"
            f"  stderr: {_captured(e.stderr)}"
        ) from None
    elapsed = time.monotonic() - started
    match = RESULT_RE.findall(proc.stdout)
    if proc.returncode != 0 or not match:
        raise CaseFailure(
            f"rpc call failed (exit {proc.returncode}) after {elapsed:.1f}s\n"
            f"  expr: {expr}\n"
            f"  stdout: {proc.stdout.strip()}\n"
            f"  stderr: {proc.stderr.strip()}"
        )
    return match[-1]


def rpc_int(expr):
    value = rpc(expr)
    try:
        return int(value)
    except ValueError as e:
        raise CaseFailure(f"expected an integer rpc result, got {value!r} (expr: {expr})") from e


class SuspendedPoller:
    def __enter__(self):
        rpc(':sys.suspend(Cinder.Download.Poller); IO.puts("RPCRESULT:ok")')
        return self

    def __exit__(self, *exc):
        rpc(':sys.resume(Cinder.Download.Poller); IO.puts("RPCRESULT:ok")')
        return False


_next_tmdb_id = [-900001]


def _fresh_tmdb_id():
    value = _next_tmdb_id[0]
    _next_tmdb_id[0] -= 1
    return value


def _elixir_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def seed_movie(title, poster_path=None, imdb_suffix=None):
    """`Catalog.add_movie/1` — a bare changeset+insert, confirmed network-free (verified running
    the container with --network none). Every seeded row gets a non-blank imdb_id so a stray
    poller tick outside a suspend bracket can never trigger a real TMDB lookup."""
    tmdb_id = _fresh_tmdb_id()
    imdb_id = f"tt9{abs(tmdb_id):06d}" if imdb_suffix is None else imdb_suffix
    fields = f"tmdb_id: {tmdb_id}, title: {_elixir_string(title)}, imdb_id: {_elixir_string(imdb_id)}"
    if poster_path:
        fields += f", poster_path: {_elixir_string(poster_path)}"
    return rpc_int(
        f"{{:ok, m}} = Cinder.Catalog.add_movie(%{{{fields}}}); "
        f'IO.puts("RPCRESULT:" <> Integer.to_string(m.id))'
    )


def lifecycle(movie_id, verb_call):
    """Drives the real movie lifecycle (`Cinder.Catalog.MovieLifecycle`) against a seeded row,
    exactly as the app's own pollers/live views do: `verb_call` runs on the freshly read `movie`
    and broadcasts `{:movie_updated, movie}` on "movies"."""
    rpc(
        f"movie = Cinder.Repo.get!(Cinder.Catalog.Movie, {movie_id}); "
        f"{{:ok, _}} = Cinder.Catalog.MovieLifecycle.{verb_call}; "
        f'IO.puts("RPCRESULT:ok")'
    )


def start_search(movie_id):
    """:requested -> :searching."""
    lifecycle(movie_id, "start_search(movie, movie.imdb_id)")


def start_download(movie_id, progress):
    """:searching -> :downloading, then one progress write. The download fields stay nil, so a
    poller tick after the case sees no client for the row, as before."""
    lifecycle(
        movie_id,
        "attach(movie, %{download_id: nil, download_protocol: nil, release_title: nil, "
        "release_policy_snapshot: nil})",
    )
    track_progress(movie_id, progress)


def track_progress(movie_id, progress):
    """A same-status progress-only update on a :downloading row."""
    lifecycle(movie_id, f"track(movie, %{{download_progress: {progress}}})")


def broadcast_movie_created(movie_id):
    """The real second half of movie creation — Catalog.add_movie/1 itself never broadcasts;
    `{:movie_created, movie}` is announced separately, normally by
    `Requests.Approval.Movie.publish/2` post-commit. We can't reach that (it needs a real TMDB
    round trip via `Requests.create_request/2`), so we call the same real, public announcement it
    calls, `Cinder.Catalog.Events.movie_created/1`."""
    rpc(
        f"movie = Cinder.Repo.get!(Cinder.Catalog.Movie, {movie_id}); "
        f"Cinder.Catalog.Events.movie_created(movie); "
        f'IO.puts("RPCRESULT:ok")'
    )


def set_poster_path(movie_id, poster_path):
    """Writes a new `poster_path` and announces the fresh row with
    `Cinder.Catalog.Events.movie_updated/1`. `/library` upserts the struct the announcement
    carries, so the card re-renders with the new `src`. A plain field write: the poster is
    metadata, not a lifecycle status."""
    rpc(
        f"movie = Cinder.Catalog.Movie |> Cinder.Repo.get!({movie_id}) "
        f"|> Ecto.Changeset.change(poster_path: {_elixir_string(poster_path)}) "
        f"|> Cinder.Repo.update!(); "
        f"Cinder.Catalog.Events.movie_updated(movie); "
        f'IO.puts("RPCRESULT:ok")'
    )


# ---------------------------------------------------------------------------------------------
# Browser-side harness
# ---------------------------------------------------------------------------------------------

KINDLE_OBSERVER_INIT_SCRIPT = """
(() => {
  // Watching for `classList.add("is-kindled")` directly, rather than diffing the `class`
  // attribute via MutationObserver, is deliberate: a MutationObserver on this page proved
  // unreliable in headless Chromium for the span<->div remount specifically — sometimes
  // delivering the single real mutation as two identical records, sometimes as zero, verified
  // against a `DOMTokenList.prototype.add` call-count spy while debugging this script (the spy
  // itself always reported exactly one real call). Element identity for a `DOMTokenList` isn't
  // otherwise queryable, so the `classList` getter is wrapped once to remember which element
  // owns which token list.
  //
  // Blind spot this trades in: it observes `classList.add` calls only. `is-kindled` is applied
  // in exactly one place today (Kindle.kindle() in app.js), via `classList.add`, so there's no
  // gap right now — but a future rewrite of `Kindle.kindle()` that used `setAttribute("class",
  // ...)` or `className = ...` instead would silently defeat this. Cases 1/3/4 would then read
  // `flare_count() === 0` as a pass while a real flare fired unobserved. Whoever next touches
  // `Kindle.kindle()`'s DOM-mutation mechanism should also update this spy.
  window.__kindleFlares = {};
  window.__kindleFilters = {};
  const tokenListOwner = new WeakMap();
  const classListDescriptor = Object.getOwnPropertyDescriptor(Element.prototype, "classList");
  Object.defineProperty(Element.prototype, "classList", {
    configurable: true,
    get() {
      const list = classListDescriptor.get.call(this);
      if (!tokenListOwner.has(list)) tokenListOwner.set(list, this);
      return list;
    },
  });
  const originalAdd = DOMTokenList.prototype.add;
  DOMTokenList.prototype.add = function (...tokens) {
    const result = originalAdd.apply(this, tokens);
    if (tokens.includes("is-kindled")) {
      const el = tokenListOwner.get(this);
      const id = (el && el.id) || "(no-id)";
      window.__kindleFlares[id] = (window.__kindleFlares[id] || 0) + 1;
      if (el) window.__kindleFilters[id] = getComputedStyle(el).filter;
    }
    return result;
  };
})();
"""

# Case 11's software authenticator (#1560). It replaces navigator.credentials.create and .get with
# an ES256 key made by WebCrypto, so the passkey hooks (assets/js/passkeys.js) and the release's
# WebAuthn check (Wax) run end to end in headless Chromium, which shows no passkey dialog.
# Chromium refuses an IP address as a relying party ID, and CI serves Cinder as
# PHX_HOST=127.0.0.1, so a real ceremony cannot run here. The stub writes the origin the server
# expects, `https://<rp id>` (prod serves https on port 443), into its client data. Its credential
# lives in localStorage, so a sign-in after the cookies are cleared finds it.
SOFT_AUTHENTICATOR_INIT_SCRIPT = """
(() => {
  const KEY = "cinder-ci-passkey";
  const enc = new TextEncoder();
  const concat = (...parts) => {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  };
  const b64url = bytes => btoa(String.fromCharCode(...bytes))
    .replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
  const unb64url = text => {
    const b = text.replace(/-/g, "+").replace(/_/g, "/");
    return Uint8Array.from(atob(b + "=".repeat((4 - b.length % 4) % 4)), c => c.charCodeAt(0));
  };
  const bytesOf = value => new Uint8Array(value instanceof ArrayBuffer ? value : value.buffer
    .slice(value.byteOffset, value.byteOffset + value.byteLength));
  const sha256 = async bytes => new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  // CBOR heads for the few shapes an attestation needs (RFC 8949 section 3).
  const head = (major, length) => length < 24 ? Uint8Array.of(major << 5 | length)
    : length < 256 ? Uint8Array.of(major << 5 | 24, length)
    : Uint8Array.of(major << 5 | 25, length >> 8, length & 255);
  const cborBytes = bytes => concat(head(2, bytes.length), bytes);
  const cborText = text => concat(head(3, enc.encode(text).length), enc.encode(text));
  const u32 = n => Uint8Array.of(n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255);
  // WebCrypto signs ECDSA as raw r || s; WebAuthn's ES256 signature is DER.
  const derInt = bytes => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    const v = bytes.slice(i);
    return v[0] & 128 ? concat(Uint8Array.of(2, v.length + 1, 0), v)
      : concat(Uint8Array.of(2, v.length), v);
  };
  const der = raw => {
    const body = concat(derInt(raw.slice(0, 32)), derInt(raw.slice(32)));
    return concat(Uint8Array.of(48, body.length), body);
  };
  const clientData = (type, challenge, rpId) => enc.encode(JSON.stringify({
    type, challenge: b64url(bytesOf(challenge)), origin: `https://${rpId}`, crossOrigin: false,
  }));
  const credential = (rawId, response) => ({
    id: b64url(rawId), rawId: rawId.buffer, type: "public-key", response,
    getClientExtensionResults: () => ({}),
  });

  async function create({publicKey}) {
    const rpId = publicKey.rp.id;
    const pair = await crypto.subtle.generateKey(
      {name: "ECDSA", namedCurve: "P-256"}, true, ["sign"]);
    const point = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
    // COSE key {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}.
    const coseKey = concat(Uint8Array.of(0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21),
      cborBytes(point.slice(1, 33)), Uint8Array.of(0x22), cborBytes(point.slice(33)));
    const rawId = crypto.getRandomValues(new Uint8Array(16));
    // Flags UP | UV | AT, sign count 0, a zero AAGUID.
    const authData = concat(await sha256(enc.encode(rpId)), Uint8Array.of(0x45), u32(0),
      new Uint8Array(16), Uint8Array.of(0, rawId.length), rawId, coseKey);
    const attestationObject = concat(Uint8Array.of(0xa3), cborText("fmt"), cborText("none"),
      cborText("attStmt"), Uint8Array.of(0xa0), cborText("authData"), cborBytes(authData));
    localStorage.setItem(KEY, JSON.stringify({
      rawId: b64url(rawId), userHandle: b64url(bytesOf(publicKey.user.id)), signCount: 0,
      key: await crypto.subtle.exportKey("jwk", pair.privateKey),
    }));
    return credential(rawId, {
      clientDataJSON: clientData("webauthn.create", publicKey.challenge, rpId).buffer,
      attestationObject: attestationObject.buffer,
    });
  }

  async function get({publicKey}) {
    const stored = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!stored) throw new DOMException("no credential", "NotAllowedError");
    stored.signCount += 1;
    localStorage.setItem(KEY, JSON.stringify(stored));
    const key = await crypto.subtle.importKey(
      "jwk", stored.key, {name: "ECDSA", namedCurve: "P-256"}, false, ["sign"]);
    const clientDataJSON = clientData("webauthn.get", publicKey.challenge, publicKey.rpId);
    // Flags UP | UV.
    const authData = concat(await sha256(enc.encode(publicKey.rpId)), Uint8Array.of(0x05),
      u32(stored.signCount));
    const raw = new Uint8Array(await crypto.subtle.sign({name: "ECDSA", hash: "SHA-256"}, key,
      concat(authData, await sha256(clientDataJSON))));
    return credential(unb64url(stored.rawId), {
      clientDataJSON: clientDataJSON.buffer, authenticatorData: authData.buffer,
      signature: der(raw).buffer, userHandle: unb64url(stored.userHandle).buffer,
    });
  }

  window.__softAuthenticatorCalls = [];
  Object.defineProperty(navigator, "credentials", {configurable: true, value: {
    create: options => { window.__softAuthenticatorCalls.push("create"); return create(options); },
    get: options => { window.__softAuthenticatorCalls.push("get"); return get(options); },
  }});
})();
"""


def flare_count(page, badge_id):
    return page.evaluate("(id) => window.__kindleFlares[id] || 0", badge_id)


def flare_filter(page, badge_id):
    return page.evaluate("(id) => window.__kindleFilters[id] || null", badge_id)


POSTER_BEHAVIOR = {}  # poster_path suffix -> "fail" | "success" | "stall"
# Requests the "stall" behavior holds open. The case that stalls them aborts them before it
# ends: Playwright prints a CancelledError traceback for a route still pending at browser close.
STALLED_ROUTES = []
# The poster fade-in transition (app.css `.poster-fade.poster-shown`, 320 ms) plus headroom. A
# read this long after a patch sees a poster the patch faded out at opacity 0, not mid-fade.
POSTER_FADE_SETTLE_MS = 1_000


def handle_poster_route(route):
    url = route.request.url
    behavior = next((b for path, b in POSTER_BEHAVIOR.items() if url.endswith(path)), None)
    if behavior == "success":
        route.fulfill(status=200, content_type="image/png", body=TINY_PNG)
    elif behavior == "fail":
        route.abort()
    elif behavior == "stall":
        STALLED_ROUTES.append(route)  # no answer, so the image stays loading
    else:
        # Any poster path we didn't seed ourselves must never reach the real CDN.
        route.abort()


# The readiness check after a navigation, over either LiveView transport. Navigations keep
# Playwright's default "load" wait, not "networkidle" (#1030): on a loaded runner the WebSocket
# can miss longPollFallbackMs, and a connected long-poll client keeps a poll request open, so
# the network does not go idle.
def wait_for_liveview(page):
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1, timeout=10_000)


def login(page):
    response = page.goto(f"{BASE_URL}/users/log-in")
    assert response and response.ok, "login page did not render"
    login_form = page.locator("#login_form_password")
    expect(login_form).to_be_visible()
    wait_for_liveview(page)
    login_form.get_by_label("Email", exact=True).fill(EMAIL)
    login_form.get_by_label("Password", exact=True).fill(PASSWORD)
    page.get_by_role("button", name="Log in only this time", exact=True).click()
    expect(page).to_have_url(re.compile(r"/$"), timeout=15_000)
    wait_for_liveview(page)


def goto_library(page):
    page.goto(f"{BASE_URL}/library")
    wait_for_liveview(page)


def badge_locator(page, movie_id):
    return page.locator(f"#library-movie-status-{movie_id}")


def wait_for_data_kindle(page, movie_id, predicate_js, timeout=5_000):
    """Waits for the badge's `data-kindle` attribute to satisfy `predicate_js` (a JS boolean
    expression over `v`), the deterministic proof a server push actually landed — never a sleep."""
    page.wait_for_function(
        "([id, pred]) => { const el = document.getElementById(id); "
        "if (!el) return false; const v = el.getAttribute('data-kindle'); "
        f"return el && new Function('v', 'return (' + pred + ')')(v); }}",
        arg=[f"library-movie-status-{movie_id}", predicate_js],
        timeout=timeout,
    )


def wait_for_badge_text(page, movie_id, text, timeout=5_000):
    expect(badge_locator(page, movie_id)).to_contain_text(text, timeout=timeout)


# ---------------------------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------------------------


def case_1_no_flare_on_initial_load(page):
    """No flare on initial page load — the `mounted()` first-sighting guard."""
    with SuspendedPoller():
        movie_id = seed_movie("Case1 Initial Load")
        start_search(movie_id)

    goto_library(page)
    badge_id = f"library-movie-status-{movie_id}"
    expect(badge_locator(page, movie_id)).to_be_visible(timeout=10_000)
    wait_for_data_kindle(page, movie_id, "v && v.includes('Searching')")
    # Bounded on the animation's own known lifetime, not an arbitrary sleep: a flare that fired
    # on mount is already added within one JS task; waiting past its 1400ms auto-removal window
    # rules out a delayed one too.
    page.wait_for_timeout(SETTLE_MS)

    count = flare_count(page, badge_id)
    if count != 0:
        raise CaseFailure(
            "case 1 (no flare on initial load): expected 0 flares on mount, "
            f"got {count} for badge #{badge_id} (movie {movie_id})"
        )


def case_2_exactly_one_flare_on_transition(page):
    """Exactly one flare on a genuine :requested -> :searching transition (span<->div swap) —
    the case module-scope `kindleSeen` exists for."""
    badge_id = None
    with SuspendedPoller():
        movie_id = seed_movie("Case2 Span Div Swap")
        badge_id = f"library-movie-status-{movie_id}"

        goto_library(page)
        expect(badge_locator(page, movie_id)).to_be_visible(timeout=10_000)
        before_tag = page.evaluate("(id) => document.getElementById(id)?.tagName", badge_id)
        if before_tag != "SPAN":
            raise CaseFailure(
                "case 2 setup: expected the :requested badge to render as <span>, got "
                f"<{before_tag}>"
            )

        start_search(movie_id)
        wait_for_data_kindle(page, movie_id, "v && v.includes('Searching')")
        page.wait_for_timeout(SETTLE_MS)

    after_tag = page.evaluate("(id) => document.getElementById(id)?.tagName", badge_id)
    count = flare_count(page, badge_id)
    if after_tag != "DIV":
        raise CaseFailure(
            f"case 2: expected the :searching badge to remount as <div>, got <{after_tag}> "
            "(the span<->div swap this case exists to exercise did not happen)"
        )
    if count != 1:
        raise CaseFailure(
            f"case 2 (exactly one flare across span<->div swap): expected 1 flare, got {count} "
            f"for badge #{badge_id} (movie {movie_id})"
        )


def _seed_and_advance_to_downloading(page, title):
    """Shared setup for cases 3 and 4, called from *inside* the caller's own `SuspendedPoller`
    bracket (not its own — advance_downloading() sweeps every :downloading movie every tick
    unconditionally, with no Intent required, so the caller's follow-up progress-only transition
    must stay under the same suspension as this setup or the real poller can touch the row in
    the gap). Seeds a movie, drives it through :requested -> :searching -> :downloading (a real
    flare each time, not asserted here), settles, and returns (movie_id, badge_id, baseline
    flare count) so the caller can assert on what happens *after* this point."""
    movie_id = seed_movie(title)
    badge_id = f"library-movie-status-{movie_id}"
    goto_library(page)
    expect(badge_locator(page, movie_id)).to_be_visible(timeout=10_000)

    start_search(movie_id)
    wait_for_badge_text(page, movie_id, "Searching")
    start_download(movie_id, 0.1)
    wait_for_badge_text(page, movie_id, "Downloading")
    page.wait_for_timeout(SETTLE_MS)

    return movie_id, badge_id, flare_count(page, badge_id)


def case_3_no_flare_on_progress_only_update(page):
    """No flare on a same-status progress-only update — the `updated()` unchanged-value guard.
    Deliberately drives `download_progress` (rendered as the visible progress bar/percentage),
    not `search_attempts` (rendered nowhere): a `search_attempts`-only change wouldn't patch the
    DOM at all, so `updated()` would never even fire and this case couldn't fail on revert."""
    with SuspendedPoller():
        movie_id, badge_id, baseline = _seed_and_advance_to_downloading(
            page, "Case3 Progress Tick"
        )

        track_progress(movie_id, 0.6)
        wait_for_badge_text(page, movie_id, "60%")
        page.wait_for_timeout(SETTLE_MS)

    count = flare_count(page, badge_id)
    if count != baseline:
        raise CaseFailure(
            "case 3 (no flare on same-status progress-only update): expected flare count to "
            f"stay at {baseline}, got {count} for badge #{badge_id} (movie {movie_id})"
        )


def case_4_no_false_flare_after_error_kind(page):
    """No false flare after phx:page-loading-start{kind:"error"} followed by a same-status
    progress update — the exact bug #592 shipped with."""
    with SuspendedPoller():
        movie_id, badge_id, baseline = _seed_and_advance_to_downloading(page, "Case4 Error Kind")

        page.evaluate(
            "() => window.dispatchEvent(new CustomEvent('phx:page-loading-start', "
            "{ detail: { kind: 'error' } }))"
        )

        track_progress(movie_id, 0.6)
        wait_for_badge_text(page, movie_id, "60%")
        page.wait_for_timeout(SETTLE_MS)

    count = flare_count(page, badge_id)
    if count != baseline:
        raise CaseFailure(
            "case 4 (no false flare after a same-View reconnect): expected flare count to stay "
            f"at {baseline} after a kind:'error' page-loading-start, got {count} for badge "
            f"#{badge_id} (movie {movie_id}) — kindleSeen was wrongly cleared"
        )


def case_5_live_inserted_poster(page):
    """A poster inserted by a pure PubSub-driven handle_info re-render (no navigation, no
    page-loading event at all) still gets failure handling via LiveSocket's onPatchEnd sweep.
    Self-contained: navigates to /library itself rather than assuming a prior case left the
    page there, so cases stay independently runnable regardless of CASES order or subsetting.
    Navigate-and-settle happens before the movie exists, so its arrival is still a pure
    broadcast into an already-mounted page, not something picked up by page load."""
    poster_path = "/case5-live-insert.jpg"
    POSTER_BEHAVIOR[poster_path] = "fail"

    with SuspendedPoller():
        goto_library(page)

        movie_id = seed_movie("Case5 Live Insert", poster_path=poster_path)
        broadcast_movie_created(movie_id)

        card_img = page.locator(f"#movie-{movie_id} img[data-poster]")
        expect(card_img).to_have_count(1, timeout=5_000)
        expect(card_img).to_have_attribute("data-poster-seen", "1", timeout=5_000)
        expect(card_img).to_have_class(re.compile(r"\bposter-broken\b"), timeout=5_000)

        # Read before the bracket exits — see case 6's identical comment.
        display = card_img.evaluate("(el) => getComputedStyle(el).display")
    if display != "none":
        raise CaseFailure(
            "case 5 (live-inserted poster gets failure handling): expected the live-inserted "
            f"<img> to end up display:none (.poster-broken), computed display was {display!r} "
            f"for movie {movie_id}"
        )


def case_6_cached_failure_before_listener_attach(page):
    """A poster that already failed (complete && naturalWidth === 0) before app.js's listener
    ever attaches still gets failure handling — the "most common failure case" per app.js's own
    comment. A same-load control poster that succeeds proves the pipeline distinguishes success
    from failure rather than marking everything broken unconditionally."""
    fail_path = "/case6-cached-failure.jpg"
    ok_path = "/case6-control-success.jpg"
    POSTER_BEHAVIOR[fail_path] = "fail"
    POSTER_BEHAVIOR[ok_path] = "success"

    with SuspendedPoller():
        fail_id = seed_movie("Case6 Cached Failure AAA", poster_path=fail_path)
        ok_id = seed_movie("Case6 Control Success AAB", poster_path=ok_path)

        goto_library(page)

        fail_img = page.locator(f"#movie-{fail_id} img[data-poster]")
        ok_img = page.locator(f"#movie-{ok_id} img[data-poster]")
        expect(fail_img).to_have_class(re.compile(r"\bposter-broken\b"), timeout=5_000)
        # The control is asserted by outcome (loaded and fully opaque), never by `.poster-shown`.
        # app.js adds that class only on its fade-in branch (the image was still loading when a
        # sweep ran), so whether it is present depends on whether the image finished before or
        # after that sweep, not on anything a user sees. A poster that already finished loading
        # is deliberately left unfaded: a cached grid renders instantly.
        expect(ok_img).to_have_js_property("naturalWidth", 1, timeout=5_000)
        expect(ok_img).to_have_css("opacity", "1", timeout=5_000)

        # Read the final computed state before the bracket exits and the real poller resumes:
        # once resumed, its very next tick can touch these still-:requested movies and cause a
        # live re-render. Case 8 covers a re-render; this case covers the first sweep alone.
        fail_display = fail_img.evaluate("(el) => getComputedStyle(el).display")
        ok_broken = ok_img.evaluate("(el) => el.classList.contains('poster-broken')")

    if fail_display != "none":
        raise CaseFailure(
            "case 6 (cached failure before listener attach): expected the pre-failed poster to "
            f"be display:none, computed display was {fail_display!r} for movie {fail_id}"
        )
    if ok_broken:
        raise CaseFailure(
            "case 6 control: the succeeding poster picked up .poster-broken too — the suite "
            f"can't distinguish success from failure (movie {ok_id})"
        )


def case_7_reduced_motion_static_alternative(page):
    """Under prefers-reduced-motion: reduce, the static saturate(1.6) alternative applies during
    a flare instead of the signal being erased by the generic 0.01ms global motion reset."""
    with SuspendedPoller():
        movie_id = seed_movie("Case7 Reduced Motion")
        badge_id = f"library-movie-status-{movie_id}"
        goto_library(page)
        expect(badge_locator(page, movie_id)).to_be_visible(timeout=10_000)

        start_search(movie_id)
        wait_for_badge_text(page, movie_id, "Searching")
        page.wait_for_timeout(SETTLE_MS)

    count = flare_count(page, badge_id)
    computed_filter = flare_filter(page, badge_id)
    if count != 1:
        raise CaseFailure(
            f"case 7 setup: expected exactly 1 flare to inspect, got {count} for badge "
            f"#{badge_id} (movie {movie_id})"
        )
    if not computed_filter or "saturate(1.6)" not in computed_filter:
        raise CaseFailure(
            "case 7 (reduced-motion static alternative): expected computed filter to contain "
            f"'saturate(1.6)' during the flare, got {computed_filter!r} for badge #{badge_id} "
            f"(movie {movie_id})"
        )


POSTER_STATE_JS = """(el) => ({
  broken: el.classList.contains("poster-broken"),
  seen: el.dataset.posterSeen ?? null,
  display: getComputedStyle(el).display,
  opacity: getComputedStyle(el).opacity,
})"""


def poster_state(img):
    """The poster's client state, read once with no retry: a wait that retried until
    `poster-broken` came back would pass a poster that showed the glyph in between."""
    return img.evaluate(POSTER_STATE_JS)


def case_8_failed_poster_survives_live_rerender(page):
    """A failed poster stays hidden when a live update re-renders its card (#702). The status
    badge is media_card's slot, so a status change re-renders the whole card and morphdom
    copies the server's attributes onto the poster <img>. That used to drop the client-added
    `poster-broken` and `data-poster-seen`, nothing processed the poster again, and the
    browser's broken-image glyph and alt text showed until the next navigation. A control
    poster that loads goes through the same re-renders and must keep showing."""
    fail_path = "/case8-rerender-failure.jpg"
    ok_path = "/case8-rerender-control.jpg"
    POSTER_BEHAVIOR[fail_path] = "fail"
    POSTER_BEHAVIOR[ok_path] = "success"

    with SuspendedPoller():
        fail_id = seed_movie("Case8 Rerender Failure", poster_path=fail_path)
        ok_id = seed_movie("Case8 Rerender Control", poster_path=ok_path)
        goto_library(page)

        fail_img = page.locator(f"#movie-{fail_id} img[data-poster]")
        ok_img = page.locator(f"#movie-{ok_id} img[data-poster]")
        expect(fail_img).to_have_class(re.compile(r"\bposter-broken\b"), timeout=5_000)
        expect(ok_img).to_have_js_property("naturalWidth", 1, timeout=5_000)
        expect(ok_img).to_have_css("opacity", "1", timeout=5_000)

        # Three re-renders of each card: :requested -> :searching (the badge swaps <span> for
        # <div>), :searching -> :downloading, then a progress write.
        states = []
        for movie_id in (fail_id, ok_id):
            start_search(movie_id)
            wait_for_badge_text(page, movie_id, "Searching")
        states.append(("searching", poster_state(fail_img), poster_state(ok_img)))
        for movie_id in (fail_id, ok_id):
            start_download(movie_id, 0.4)
            wait_for_badge_text(page, movie_id, "40%")
        states.append(("downloading", poster_state(fail_img), poster_state(ok_img)))

    for step, failed, control in states:
        if not failed["broken"] or failed["display"] != "none":
            raise CaseFailure(
                f"case 8 (failed poster survives a live re-render), after {step}: expected the "
                f"failed poster to keep .poster-broken and display:none, got {failed!r} for "
                f"movie {fail_id}"
            )
        if control["broken"] or control["display"] == "none" or control["opacity"] != "1":
            raise CaseFailure(
                f"case 8 control, after {step}: expected the loaded poster to keep showing, got "
                f"{control!r} for movie {ok_id}"
            )


def case_9_poster_src_change_is_processed_again(page):
    """A poster whose `src` a live update changes is processed again as a new image (#702): a
    failed poster that gets a working `src` shows instead of keeping the old one's broken
    state, and a working poster that gets a failing `src` hides instead of showing the glyph.
    LiveView keeps the same <img> element across both patches."""
    first_fail = "/case9-first-failure.jpg"
    then_ok = "/case9-then-success.jpg"
    then_fail = "/case9-then-failure.jpg"
    POSTER_BEHAVIOR[first_fail] = "fail"
    POSTER_BEHAVIOR[then_ok] = "success"
    POSTER_BEHAVIOR[then_fail] = "fail"

    with SuspendedPoller():
        movie_id = seed_movie("Case9 Src Change", poster_path=first_fail)
        goto_library(page)

        img = page.locator(f"#movie-{movie_id} img[data-poster]")
        expect(img).to_have_class(re.compile(r"\bposter-broken\b"), timeout=5_000)
        page.evaluate(
            "(id) => { window.__case9Img = document.querySelector(`#movie-${id} img[data-poster]`) }",
            movie_id,
        )

        set_poster_path(movie_id, then_ok)
        expect(img).to_have_attribute("src", re.compile(re.escape(then_ok) + "$"), timeout=5_000)
        expect(img).to_have_js_property("naturalWidth", 1, timeout=5_000)
        expect(img).to_have_css("opacity", "1", timeout=5_000)
        loaded = poster_state(img)

        set_poster_path(movie_id, then_fail)
        expect(img).to_have_attribute("src", re.compile(re.escape(then_fail) + "$"), timeout=5_000)
        try:
            expect(img).to_have_class(re.compile(r"\bposter-broken\b"), timeout=5_000)
        except AssertionError:
            pass  # reported below with the full state
        failed_again = poster_state(img)
        same_element = page.evaluate(
            "(id) => window.__case9Img === document.querySelector(`#movie-${id} img[data-poster]`)",
            movie_id,
        )

    if not same_element:
        raise CaseFailure(
            "case 9 setup: LiveView replaced the poster <img> instead of patching its src, so "
            f"this case no longer tests a src change on one element (movie {movie_id})"
        )
    if loaded["broken"] or loaded["display"] == "none":
        raise CaseFailure(
            "case 9 (src change, failure -> success): expected the poster to show its new image, "
            f"got {loaded!r} for movie {movie_id}"
        )
    if not failed_again["broken"] or failed_again["display"] != "none":
        raise CaseFailure(
            "case 9 (src change, success -> failure): expected the poster to hide its new failed "
            f"image with .poster-broken and display:none, got {failed_again!r} for movie "
            f"{movie_id}"
        )


def case_10_stalled_poster_stays_revealed_across_live_rerender(page):
    """A poster whose request never answers is revealed by app.js's 3-second fallback, and a
    live re-render of its card keeps it revealed (#702). The fix carries the client state
    across a patch that keeps the src. Processing such a poster again after the patch instead
    would fade it out once more on every re-render, since it is still loading."""
    stall_path = "/case10-stalled.jpg"
    POSTER_BEHAVIOR[stall_path] = "stall"

    with SuspendedPoller():
        try:
            movie_id = seed_movie("Case10 Stalled Poster", poster_path=stall_path)
            goto_library(page)

            img = page.locator(f"#movie-{movie_id} img[data-poster]")
            expect(img).to_have_class(re.compile(r"\bposter-shown\b"), timeout=10_000)
            before = img.evaluate("(el) => ({complete: el.complete})")

            start_search(movie_id)
            wait_for_badge_text(page, movie_id, "Searching")
            page.wait_for_timeout(POSTER_FADE_SETTLE_MS)
            after = poster_state(img)
        finally:
            while STALLED_ROUTES:
                STALLED_ROUTES.pop().abort()

    if before["complete"]:
        raise CaseFailure(
            "case 10 setup: the stalled poster finished loading, so this case no longer tests a "
            f"poster that is still loading (movie {movie_id})"
        )
    if after["broken"] or after["display"] == "none" or after["opacity"] != "1":
        raise CaseFailure(
            "case 10 (stalled poster stays revealed across a live re-render): expected opacity 1 "
            f"and no .poster-broken after the re-render, got {after!r} for movie {movie_id}"
        )


def flash_texts(page):
    return page.locator("#flash-info, #flash-error").all_inner_texts()


def case_11_passkey_add_then_sign_in(page):
    """A user adds a passkey in Account settings, then signs in with it from a fresh cookie jar
    (#1560). It runs the PasskeyRegister and PasskeySignIn hooks of assets/js/passkeys.js against
    the release's WebAuthn check, through SOFT_AUTHENTICATOR_INIT_SCRIPT. Its own browser context
    keeps the sign-out away from the other cases' page."""
    context = page.context.browser.new_context(viewport={"width": 1440, "height": 900})
    try:
        passkey_page = context.new_page()
        passkey_page.add_init_script(SOFT_AUTHENTICATOR_INIT_SCRIPT)
        login(passkey_page)

        passkey_page.goto(f"{BASE_URL}/users/settings")
        wait_for_liveview(passkey_page)
        passkey_page.locator("#new_passkey_name").fill("CI key")
        passkey_page.locator("#add_passkey_button").click()
        try:
            # The name shows as the value of the passkey's rename field.
            expect(passkey_page.locator("#passkey_list input[name=name]")).to_have_value(
                "CI key", timeout=10_000
            )
            # The hook clears the field only once the server's reply says the passkey is stored.
            expect(passkey_page.locator("#new_passkey_name")).to_have_value("", timeout=5_000)
        except AssertionError as error:
            raise CaseFailure(
                "case 11 (add a passkey): expected one 'CI key' row in #passkey_list, got flash "
                f"{flash_texts(passkey_page)!r} and authenticator "
                f"calls {passkey_page.evaluate('window.__softAuthenticatorCalls')!r}"
            ) from error

        context.clear_cookies()
        response = passkey_page.goto(f"{BASE_URL}/users/log-in")
        assert response and response.ok, "login page did not render"
        wait_for_liveview(passkey_page)
        passkey_page.locator("#passkey_login_button").click()
        try:
            expect(passkey_page).to_have_url(re.compile(r"/$"), timeout=15_000)
            expect(passkey_page.get_by_text("Welcome back!")).to_be_visible()
        except AssertionError as error:
            raise CaseFailure(
                "case 11 (sign in with the passkey): expected '/' and 'Welcome back!', got "
                f"{passkey_page.url} with flash {flash_texts(passkey_page)!r}"
            ) from error
    finally:
        context.close()


def seed_indexer(name, priority):
    """Creates an enabled configured Newznab indexer on a host that never answers, and returns
    its id. Nothing in the case sends it a request: the case never presses Test."""
    return rpc_int(
        "{:ok, row} = Cinder.Indexers.create(nil, %{"
        f"name: {_elixir_string(name)}, type: :newznab, priority: {priority}, "
        f'base_url: "https://{name.lower().replace(" ", "-")}.invalid", api_path: "/api"'
        '}, %{"api_key" => "ci-key"}); IO.puts("RPCRESULT:#{row.id}")'
    )


def delete_indexer(indexer_id):
    rpc(
        f"Cinder.Indexers.delete(nil, {indexer_id}); "
        'IO.puts("RPCRESULT:ok")'
    )


def case_12_indexer_switches_in_the_settings_form(page):
    """The indexers table in /settings (#1660). With focus on a row's enable switch, Enter and
    Space each toggle it and neither submits #settings-form, whose save flashes "Settings
    saved.". After the first row is deleted from the keyboard, focus is on the remaining row's
    Delete and that row's switch reads its own state, not the deleted row's. At 390 px wide the
    page has no horizontal scroll, and a sideways wheel over the table scrolls the table's own
    box until the row's Delete button shows. The second row's
    name has no place to break a line, so the table is wider than the group: the group clips what
    sticks out, and without that box the button stays out of reach. Its own browser context keeps
    the narrow viewport away from the other cases."""
    first = seed_indexer("CI Indexer Alpha", 10)
    second = seed_indexer("CIIndexerBravoWithALongUnbrokenName0123456789", 20)
    context = page.context.browser.new_context(viewport={"width": 1440, "height": 900})
    try:
        settings = context.new_page()
        login(settings)
        settings.goto(f"{BASE_URL}/settings?group=indexer")
        wait_for_liveview(settings)

        switch = settings.locator(f"#indexer-{first}-enabled")
        notice = settings.locator("#indexers-notice")
        expect(switch).to_have_attribute("aria-checked", "true")

        switch.focus()
        settings.keyboard.press("Enter")
        expect(switch).to_have_attribute("aria-checked", "false", timeout=5_000)
        expect(notice).to_have_text("CI Indexer Alpha disabled.")
        settings.keyboard.press("Space")
        expect(switch).to_have_attribute("aria-checked", "true", timeout=5_000)
        expect(notice).to_have_text("CI Indexer Alpha enabled.")
        if any("Settings saved." in text for text in flash_texts(settings)):
            raise CaseFailure(
                "case 12 (switch keys): Enter or Space on an indexer switch submitted "
                f"#settings-form, flash {flash_texts(settings)!r}"
            )

        # The second row off, the first on: a state carried over by position would show.
        settings.locator(f"#indexer-{second}-enabled").click()
        expect(settings.locator(f"#indexer-{second}-enabled")).to_have_attribute(
            "aria-checked", "false", timeout=5_000
        )
        # Deleted from the keyboard: focus moves to the next row's Delete, not to the page.
        settings.once("dialog", lambda dialog: dialog.accept())
        settings.locator(f"#indexer-{first}-delete").focus()
        settings.keyboard.press("Enter")
        expect(settings.locator(f"#indexer-{first}")).to_have_count(0, timeout=5_000)
        expect(settings.locator(f"#indexer-{second}-delete")).to_be_focused()
        expect(settings.locator(f"#indexer-{second}-enabled")).to_have_attribute(
            "aria-checked", "false"
        )

        settings.set_viewport_size({"width": 390, "height": 844})
        settings.reload()
        wait_for_liveview(settings)
        expect(settings.locator(f"#indexer-{second}")).to_be_visible()
        widths = settings.evaluate(
            "[document.documentElement.scrollWidth, document.documentElement.clientWidth]"
        )
        if widths[0] > widths[1]:
            raise CaseFailure(
                f"case 12 (390 px): the page scrolls sideways, scrollWidth {widths[0]} over "
                f"clientWidth {widths[1]}"
            )

        delete_id = f"indexer-{second}-delete"
        name_cell = settings.locator(f"#indexer-{second} td").first
        # Centres the row vertically. The name cell is already in view sideways, so nothing
        # scrolls sideways here, and the Delete button below it stays inside the viewport.
        name_cell.evaluate("(cell) => cell.scrollIntoView({block: 'center', inline: 'nearest'})")
        name_cell.hover()
        settings.mouse.wheel(600, 0)
        # Polls up to 5 s until the point at the button's centre hits the button: nothing clips
        # it. Each answer also carries the button's box for the failure message.
        reach = None
        for _ in range(50):
            reach = settings.evaluate(
                """(id) => {
                  const button = document.getElementById(id);
                  const box = button.getBoundingClientRect();
                  const hit = document.elementFromPoint(
                    box.left + box.width / 2, box.top + box.height / 2);
                  return {hit: !!hit && button.contains(hit),
                          box: [box.left, box.right, box.top, box.bottom]};
                }""",
                delete_id,
            )
            if reach["hit"]:
                break
            settings.wait_for_timeout(100)
        if not reach["hit"]:
            left, right, top, bottom = reach["box"]
            raise CaseFailure(
                "case 12 (390 px): a sideways wheel over the table left its Delete button out of "
                f"reach, at left {left}, right {right}, top {top}, bottom {bottom} px"
            )
    finally:
        context.close()
        delete_indexer(first)
        delete_indexer(second)


def start_indexer_test(indexer_id):
    """Starts a per-indexer Test in the running node, as the table's Test button does. A seeded
    indexer's host ends in `.invalid`, so its Test ends at once on a failed lookup."""
    rpc(
        f"Cinder.Acquisition.IndexerSource.Native.TestRunner.start({indexer_id}); "
        'IO.puts("RPCRESULT:ok")'
    )


def focus_in(page, selector):
    return page.evaluate(
        "(selector) => !!document.querySelector(selector)?.contains(document.activeElement)",
        selector,
    )


def case_13_indexer_dialogs(page):
    """The Add and Edit dialogs of the indexers table (#1661). With the edit dialog open and a
    name and key typed: #settings-form's FormData holds no indexer field and the dialog's form is
    not inside #settings-form; the typed name and key stay after another row's Test ends and
    after the edited row's Test ends; Tab stays inside the dialog. Escape closes each dialog and
    focus returns to the button that opened it, and a real save of a typed key stores it and
    returns focus to its Edit button."""
    first = seed_indexer("CI Dialog Alpha", 30)
    second = seed_indexer("CI Dialog Bravo", 31)
    context = page.context.browser.new_context(viewport={"width": 1440, "height": 900})
    try:
        settings = context.new_page()
        login(settings)
        settings.goto(f"{BASE_URL}/settings?group=indexer")
        wait_for_liveview(settings)
        notice = settings.locator("#indexers-notice")
        box = settings.locator("#indexer-dialog-box")
        edit = settings.locator(f"#indexer-{first}-edit")

        edit.focus()
        settings.keyboard.press("Enter")
        expect(box).to_be_visible(timeout=5_000)
        settings.wait_for_function(
            "() => document.getElementById('indexer-dialog-box')"
            "?.contains(document.activeElement)",
            timeout=5_000,
        )
        name = settings.locator("#indexer-form-name")
        key = settings.locator("#indexer-form input[name='secrets[api_key]']")
        name.fill("CI typed name")
        key.fill("ci-typed-key")
        # LiveView marks the form while a change event awaits its reply: once the mark is gone,
        # the typed name is in the component's assigns.
        expect(settings.locator("#indexer-form.phx-change-loading")).to_have_count(0)

        leaks = settings.evaluate(
            """() => {
              const form = document.getElementById("settings-form");
              const names = [...new FormData(form).keys()];
              return {names: names.filter((n) => /^(indexer|secrets)\\[/.test(n)),
                      nested: form.contains(document.getElementById("indexer-form")),
                      total: names.length};
            }"""
        )
        if leaks["names"] or leaks["nested"] or leaks["total"] == 0:
            raise CaseFailure(
                "case 13 (portal): #settings-form holds indexer fields or the dialog form, "
                f"{leaks!r}"
            )

        for indexer_id, label in [(second, "CI Dialog Bravo"), (first, "CI Dialog Alpha")]:
            start_indexer_test(indexer_id)
            expect(notice).to_contain_text(f"Test of {label}", timeout=15_000)
            expect(name).to_have_value("CI typed name")
            expect(key).to_have_value("ci-typed-key")

        # Tab past every control twice over: focus never leaves the dialog.
        for step in range(30):
            settings.keyboard.press("Tab")
            if not focus_in(settings, "#indexer-dialog-box"):
                raise CaseFailure(f"case 13 (Tab): focus left the dialog after {step + 1} Tab(s)")

        settings.keyboard.press("Escape")
        expect(box).to_have_count(0, timeout=5_000)
        expect(edit).to_be_focused()

        add = settings.locator("#indexers-add")
        add.focus()
        settings.keyboard.press("Enter")
        expect(settings.locator("#indexer-kind-query")).to_be_focused(timeout=5_000)
        settings.keyboard.press("Escape")
        expect(box).to_have_count(0, timeout=5_000)
        expect(add).to_be_focused()

        edit.click()
        expect(box).to_be_visible(timeout=5_000)
        settings.locator("#indexer-form-name").fill("CI Dialog Saved")
        settings.locator("#indexer-form input[name='secrets[api_key]']").fill("ci-saved-key")
        settings.locator("#indexer-form-save").click()
        expect(notice).to_have_text("CI Dialog Saved saved.", timeout=5_000)
        expect(box).to_have_count(0)
        expect(edit).to_be_focused()
        stored = rpc(
            f"{{:ok, row}} = Cinder.Indexers.fetch_with_secrets({first}); "
            'IO.puts("RPCRESULT:#{row.name}|#{row.secrets["api_key"] == "ci-saved-key"}")'
        )
        if stored != "CI Dialog Saved|true":
            raise CaseFailure(f"case 13 (save): the store read back {stored!r}")
    finally:
        context.close()
        delete_indexer(first)
        delete_indexer(second)


def case_14_refused_credential_clears_the_focused_input(page):
    """A refused base URL, API path or additional parameters value can carry a credential
    (#1697). In the Add dialog and in the Edit dialog, a credential typed into one of these
    fields, with focus kept there and the form submitted with Enter, leaves that focused input
    empty with its refusal's message, while the other fields keep their valid values. With the
    base URL and the additional parameters both refused, both end empty. Text typed after a
    refusal stays in the input, and so does the typed name."""
    credential = "ci-cred-7d1f3b"
    edited = seed_indexer("CI Refused Edit", 32)
    context = page.context.browser.new_context(viewport={"width": 1440, "height": 900})
    try:
        settings = context.new_page()
        login(settings)
        settings.goto(f"{BASE_URL}/settings?group=indexer")
        wait_for_liveview(settings)
        box = settings.locator("#indexer-dialog-box")
        name = settings.locator("#indexer-form-name")
        base_url = settings.locator("#indexer-form-base-url")
        api_path = settings.locator("#indexer-form-api-path")
        parameters = settings.locator("#indexer-form-additional-parameters")
        loading = settings.locator("#indexer-form.phx-change-loading")

        userinfo = f"https://u:{credential}@indexer.example"
        query = f"/api?apikey={credential}"
        apikey = f"&apikey={credential}"
        base_url_error = "Remove the user name and password from the URL."
        api_path_error = "Enter a path that starts with a single /, such as /api."
        parameters_error = "Put the API key in the API key field, not in additional parameters."

        # Fills each (input, value, its refusal's message), then submits with Enter from the last
        # input, which keeps focus. Every input holds its typed value before the submit. An
        # earlier submit's message can still show, so the wait on the reply is each refused
        # input's value turning "", and each message is read after it.
        def submit(label, refused):
            for field, value, _message in refused:
                field.fill(value)
            expect(loading).to_have_count(0)
            for field, value, _message in refused:
                expect(field).to_have_value(value)
            refused[-1][0].press("Enter")
            for field, _value, message in refused:
                try:
                    expect(field).to_have_value("", timeout=5_000)
                except AssertionError as e:
                    raise CaseFailure(
                        f"case 14 ({label}): a refused input kept its value after the submit, {e}"
                    ) from e
                error = settings.locator(f"#{field.get_attribute('id')}-error")
                expect(error).to_contain_text(message)

        def open_add():
            settings.locator("#indexers-add").click()
            settings.locator("#indexer-kind-newznab").click()

        def open_edit():
            settings.locator(f"#indexer-{edited}-edit").click()

        for dialog, open_dialog in [("add", open_add), ("edit", open_edit)]:
            open_dialog()
            expect(name).to_be_visible(timeout=5_000)
            name.fill("CI Refused Credential")

            submit(f"{dialog}, base URL", [(base_url, userinfo, base_url_error)])
            expect(base_url).to_be_focused()

            base_url.fill("https://ci-refused.invalid")
            submit(f"{dialog}, API path", [(api_path, query, api_path_error)])
            expect(api_path).to_be_focused()
            expect(base_url).to_have_value("https://ci-refused.invalid")

            api_path.fill("/api")
            submit(f"{dialog}, additional parameters", [(parameters, apikey, parameters_error)])
            expect(parameters).to_be_focused()
            expect(base_url).to_have_value("https://ci-refused.invalid")
            expect(api_path).to_have_value("/api")
            expect(settings.locator("#indexer-form-base-url-error")).to_have_count(0)
            expect(settings.locator("#indexer-form-api-path-error")).to_have_count(0)

            submit(
                f"{dialog}, both, from additional parameters",
                [(base_url, userinfo, base_url_error), (parameters, apikey, parameters_error)],
            )
            expect(base_url).to_be_focused(timeout=5_000)

            # Typing after the refusal: the next change's reply keeps what the admin types.
            settings.keyboard.type("https://ci-retyped.invalid")
            expect(loading).to_have_count(0)
            expect(base_url).to_have_value("https://ci-retyped.invalid")
            expect(name).to_have_value("CI Refused Credential")

            values = settings.evaluate(
                "() => [...document.querySelectorAll('#indexer-form input')].map((i) => i.value)"
            )
            if any(credential in value for value in values):
                raise CaseFailure(
                    f"case 14 ({dialog}): an input still holds the credential, {values!r}"
                )

            settings.keyboard.press("Escape")
            expect(box).to_have_count(0, timeout=5_000)
    finally:
        context.close()
        delete_indexer(edited)


def stored_indexer_source():
    return rpc(
        'IO.puts("RPCRESULT:#{inspect(Cinder.Settings.get("indexer_source"))}")'
    )


def case_15_refused_source_switch_reopens_its_group(page):
    """The "Indexer source" select in /settings (#1662). With one enabled indexer that was never
    checked, the gate fails, so a save that switches to Built-in is refused: the refusal shows
    under the select and the select takes focus. The admin then closes the Indexers group and
    saves again, and the group must open with the select focused. Two things open it: the
    `focus-invalid` push, which opens each closed `<details>` around the field
    (assets/js/focus_invalid.js), and the retry's patch, which sets the group's `open` again
    because each save clears the flash first. Run on 2026-11-26 with both taken out, the group
    stayed closed; with either one alone, it opened. Nothing is stored either time."""
    indexer = seed_indexer("CI Source Gate", 40)
    context = page.context.browser.new_context(viewport={"width": 1440, "height": 900})
    try:
        gate = rpc(
            "IO.puts(\"RPCRESULT:#{Cinder.Acquisition.IndexerSource.Native.IndexerState"
            '.passes_gate?()}")'
        )
        if gate != "false":
            raise CaseFailure(f"case 15 (setup): the gate passes before the case, got {gate!r}")
        before = stored_indexer_source()

        settings = context.new_page()
        login(settings)
        settings.goto(f"{BASE_URL}/settings?group=indexer")
        wait_for_liveview(settings)
        group = settings.locator("#settings-group-indexer")
        select = settings.locator("#indexer_source")
        refusal = settings.locator("#indexer_source-error")
        save = settings.locator("#settings-form button[type=submit]")

        select.select_option("native")
        save.click()
        expect(refusal).to_contain_text(
            "Built-in needs at least one enabled indexer", timeout=5_000
        )
        expect(select).to_be_focused(timeout=5_000)

        settings.locator("#settings-group-indexer > summary").click()
        expect(group).to_have_js_property("open", False, timeout=5_000)
        save.click()
        expect(group).to_have_js_property("open", True, timeout=5_000)
        expect(select).to_be_focused(timeout=5_000)
        expect(refusal).to_be_visible()

        after = stored_indexer_source()
        if after != before:
            raise CaseFailure(
                "case 15 (store): a refused switch changed the stored source "
                f"{before!r} to {after!r}"
            )
    finally:
        context.close()
        delete_indexer(indexer)


CASES = [
    ("case1_no_flare_on_initial_load", case_1_no_flare_on_initial_load),
    ("case2_exactly_one_flare_on_transition", case_2_exactly_one_flare_on_transition),
    ("case3_no_flare_on_progress_only_update", case_3_no_flare_on_progress_only_update),
    ("case4_no_false_flare_after_error_kind", case_4_no_false_flare_after_error_kind),
    ("case5_live_inserted_poster", case_5_live_inserted_poster),
    ("case6_cached_failure_before_listener_attach", case_6_cached_failure_before_listener_attach),
    ("case7_reduced_motion_static_alternative", case_7_reduced_motion_static_alternative),
    ("case8_failed_poster_survives_live_rerender", case_8_failed_poster_survives_live_rerender),
    ("case9_poster_src_change_is_processed_again", case_9_poster_src_change_is_processed_again),
    (
        "case10_stalled_poster_stays_revealed_across_live_rerender",
        case_10_stalled_poster_stays_revealed_across_live_rerender,
    ),
    ("case11_passkey_add_then_sign_in", case_11_passkey_add_then_sign_in),
    (
        "case12_indexer_switches_in_the_settings_form",
        case_12_indexer_switches_in_the_settings_form,
    ),
    ("case13_indexer_dialogs", case_13_indexer_dialogs),
    (
        "case14_refused_credential_clears_the_focused_input",
        case_14_refused_credential_clears_the_focused_input,
    ),
    (
        "case15_refused_source_switch_reopens_its_group",
        case_15_refused_source_switch_reopens_its_group,
    ),
]


def main():
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, channel=BROWSER_CHANNEL)
        page = browser.new_page(
            viewport={"width": 1440, "height": 900},
            color_scheme="light",
            reduced_motion="reduce",
        )
        page.add_init_script(KINDLE_OBSERVER_INIT_SCRIPT)
        page.route("**/image.tmdb.org/**", handle_poster_route)

        login(page)
        goto_library(page)

        results = []
        for name, case_fn in CASES:
            try:
                case_fn(page)
                results.append((name, True, None))
                print(f"PASS: {name}", flush=True)
            except Exception as e:  # noqa: BLE001 — every case's own exception is diagnostic
                results.append((name, False, str(e)))
                print(f"FAIL: {name}\n{e}", flush=True)
                if SCREENSHOT_DIR:
                    output = Path(SCREENSHOT_DIR)
                    output.mkdir(parents=True, exist_ok=True)
                    page.screenshot(path=output / f"{name}.png", full_page=True)

        browser.close()

        failed = [r for r in results if not r[1]]
        if failed:
            print(f"\n{len(failed)}/{len(results)} lifecycle case(s) failed:")
            for name, _, detail in failed:
                print(f" - {name}: {detail}")
            sys.exit(1)

        print(f"\nAll {len(results)} lifecycle cases passed.")


if __name__ == "__main__":
    main()
