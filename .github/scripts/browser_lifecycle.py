"""Browser-level regression coverage for the two JS lifecycles assets/js/app.js gained in #592
(Kindle status-badge flare, poster-failure handling) — issue #593.

Two real bugs shipped in #592 and reached review only after `mix test` (4422 passing) and
`browser_smoke.py` both went green, because nothing in the suite touched either lifecycle:
  - Case 4 below is the actual kindle "error"-kind false-flare bug.
  - Case 5 below is the actual live-insert poster gap.
The other five cases cover the rest of each lifecycle's real branches so a future change to
either has the same chance of being caught before review as everything else in this app.

Driving mechanism: `docker exec <container> /app/bin/cinder rpc '<expr>'`, never `eval`. `eval`
boots a disconnected temporary node (`:nonode@nohost`) whose Catalog broadcasts can never reach
the real server's mounted LiveViews. `rpc` executes *in* the running `:cinder@<host>` node, so a
`Catalog.transition/3` issued this way broadcasts on the real "movies" PubSub topic and patches
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
BROWSER_CHANNEL = os.environ.get("CINDER_SMOKE_BROWSER_CHANNEL")

RPC_TIMEOUT = 15
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


def rpc(expr, timeout=RPC_TIMEOUT):
    """Evaluates `expr` on the running server node. `expr` must end by printing
    `RPCRESULT:<value>` — Logger/telemetry output can interleave with plain stdout across the
    docker-exec boundary, so we grep for the sentinel line instead of trusting output order."""
    proc = subprocess.run(
        ["docker", "exec", CONTAINER, "/app/bin/cinder", "rpc", expr],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    match = RESULT_RE.findall(proc.stdout)
    if proc.returncode != 0 or not match:
        raise CaseFailure(
            f"rpc call failed (exit {proc.returncode})\n"
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


def transition(movie_id, fields, expect_status):
    """Drives the real Catalog choke-point (`Catalog.transition/3`) against a seeded row, exactly
    as the app's own pollers/live views do — broadcasts `{:movie_updated, movie}` on "movies"."""
    rpc(
        f"movie = Cinder.Repo.get!(Cinder.Catalog.Movie, {movie_id}); "
        f"{{:ok, _}} = Cinder.Catalog.transition(movie, %{{{fields}}}, expect: :{expect_status}); "
        f'IO.puts("RPCRESULT:ok")'
    )


def broadcast_movie_created(movie_id):
    """The real second half of movie creation — Catalog.add_movie/1 itself never broadcasts (no
    call to `broadcast`/`broadcast_movie_created` in its body); `{:movie_created, movie}` is
    announced separately, normally by `Requests.finalize_movie_approval/2` post-commit. We can't
    reach that (it needs a real TMDB round trip via `Requests.create_request/2`), so we call the
    same real, public, already-decoupled Catalog function it calls."""
    rpc(
        f"movie = Cinder.Repo.get!(Cinder.Catalog.Movie, {movie_id}); "
        f"Cinder.Catalog.broadcast_movie_created(movie); "
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


def flare_count(page, badge_id):
    return page.evaluate("(id) => window.__kindleFlares[id] || 0", badge_id)


def flare_filter(page, badge_id):
    return page.evaluate("(id) => window.__kindleFilters[id] || null", badge_id)


POSTER_BEHAVIOR = {}  # poster_path suffix -> "fail" | "success"


def handle_poster_route(route):
    url = route.request.url
    behavior = next((b for path, b in POSTER_BEHAVIOR.items() if url.endswith(path)), None)
    if behavior == "success":
        route.fulfill(status=200, content_type="image/png", body=TINY_PNG)
    elif behavior == "fail":
        route.abort()
    else:
        # Any poster path we didn't seed ourselves must never reach the real CDN.
        route.abort()


def wait_for_liveview(page):
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1, timeout=10_000)


def login(page):
    response = page.goto(f"{BASE_URL}/users/log-in", wait_until="networkidle")
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
    page.goto(f"{BASE_URL}/library", wait_until="networkidle")
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
        transition(movie_id, "status: :searching", expect_status="requested")

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

        transition(movie_id, "status: :searching", expect_status="requested")
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

    transition(movie_id, "status: :searching", expect_status="requested")
    wait_for_badge_text(page, movie_id, "Searching")
    transition(
        movie_id,
        "status: :downloading, download_progress: 0.1",
        expect_status="searching",
    )
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

        transition(
            movie_id,
            "status: :downloading, download_progress: 0.6",
            expect_status="downloading",
        )
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

        transition(
            movie_id,
            "status: :downloading, download_progress: 0.6",
            expect_status="downloading",
        )
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
    page-loading event at all) still gets failure handling via LiveSocket's onNodeAdded."""
    poster_path = "/case5-live-insert.jpg"
    POSTER_BEHAVIOR[poster_path] = "fail"

    with SuspendedPoller():
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
        expect(ok_img).to_have_class(re.compile(r"\bposter-shown\b"), timeout=5_000)

        # Read the final computed state before the bracket exits and the real poller resumes:
        # once resumed, its very next tick can touch these still-:requested movies and cause a
        # live re-render that wipes the client-only classes we're about to assert on.
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

        transition(movie_id, "status: :searching", expect_status="requested")
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


CASES = [
    ("case1_no_flare_on_initial_load", case_1_no_flare_on_initial_load),
    ("case2_exactly_one_flare_on_transition", case_2_exactly_one_flare_on_transition),
    ("case3_no_flare_on_progress_only_update", case_3_no_flare_on_progress_only_update),
    ("case4_no_false_flare_after_error_kind", case_4_no_false_flare_after_error_kind),
    ("case5_live_inserted_poster", case_5_live_inserted_poster),
    ("case6_cached_failure_before_listener_attach", case_6_cached_failure_before_listener_attach),
    ("case7_reduced_motion_static_alternative", case_7_reduced_motion_static_alternative),
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
                print(f"PASS: {name}")
            except Exception as e:  # noqa: BLE001 — every case's own exception is diagnostic
                results.append((name, False, str(e)))
                print(f"FAIL: {name}\n{e}")
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
