# Books B4c — the admin pipeline view, manual search, and Grab

**Status:** planned 2026-09-01, revised after two review rounds. Base: `origin/main` @ `9f33e7d2`
(post-B4b).
**Milestone:** the third and final slice of
[B4](2026-08-20-readarr-replacement-roadmap.md#b4--e-book-search-scoring-download-validation-and-publication).

## What B4b left, and what this slice owns

[B4a](2026-08-30-books-b4a-ebook-release-search-and-scoring.md) landed the decision layer
(`Acquisition.Books.candidates/2`, no `best_book_release/2`).
[B4b](2026-08-31-books-b4b-ebook-download-and-publication.md) landed the acquisition-to-disk
layer (`Download.grab_book_target/2`, `Download.BookPoller`, `Library.BookImport`, `book_grabs`,
`book_files`). Both shipped with **no production caller** — B4a's decision layer had nothing
calling `candidates/2`, and B4b's pipeline only runs once something calls `grab_book_target/2`.

B4c is the **operator surface**: the human end of the "ship manual release search/selection
first" gate the roadmap sets for all of B4. It gives an admin a page to open a monitored e-book
target, see what the indexer found and why each release was accepted or rejected, press Grab, and
watch the target reach `:available` or `:held`. This is also the milestone's own **Book MVP
product gate**: B4's Done-when reads "an approved corpus e-book is discovered, downloaded,
validated, published, **and shown as Available**" — until this slice ships, nothing shown to an
operator can make that happen, because nothing calls `grab_book_target/2`.

**Out of scope, deliberately** (detailed with reasoning in [§10](#10-what-stays-out)):

- Automatic selection — still no `best_book_release/2`, still no `BookPoller` search pass.
- Audiobooks.
- The `/library` books tab (see [§1](#1-scope)).
- Any metadata edit control (author aliases, operator metadata overrides — still parked).
- Retry/blocklist-clearing for a `:held` target, and re-searching an already-`:available` target
  ("Find a better match") — both explicitly B5 work per the roadmap's B5 Work list.
- Extending `/activity` to books ([§2](#2-reachability-how-an-admin-reaches-booksid)).

## Design

### 1. Scope

**`/books/:id` lands, keyed by `book_works.id`** — not by a target id. A work independently
monitors `:ebook` and `:audiobook` ([parity contract](../specs/2026-08-20-books-parity-contract.md#monitoring-semantics)),
and `Books.get_target(id)` was already built B2b-era for a single target row, but B3b's own
framing — "the admin pipeline view of a work Cinder already tracks... the books analogue of
`/movies/:id`" — is unambiguous: the page is about the work, and it must be able to show an
e-book pipeline and (read-only) an audiobook one side by side, the same way `/series/:id` shows
every season under one series.

A `book_targets` row does not necessarily exist for a media kind yet: `Books.monitor_target/4` —
the approval choke-point — is the only thing that calls `Books.ensure_target/2`, and it runs at
**approval**, not at request creation (`Requests.approve_request/3` calls it inline,
`lib/cinder/requests.ex:430`). A `book_works` row *is* created at request time (`Requests` owns
the catalog write so a refused request leaves nothing behind), so a work with a pending or denied
request can be opened at `/books/:id` with zero target rows. The page must handle that: for each
`media_kind` in `LibraryKind.books()`, render a section only from the target actually present in
`Books.get_work(id).targets`; a media kind with no target row renders a plain "not yet approved"
line, no pipeline detail, no search entry point — there is nothing to search against, because
nothing is monitored.

**Target status badge: reuse, not new markup.** Every target `/books/:id` ever renders already has
`status` in `[:monitored, :available, :held]` — `Books.ensure_target/2` defaults a fresh row to
`:unmonitored`, but `monitor_target/4` immediately arms it in the same call, and this slice ships
no "pause/resume" control ([§10](#10-what-stays-out)), so `:unmonitored` is never an observed state
here. That means the exact status vocabulary `CinderWeb.LiveHelpers.book_badge_state/2` already
maps (`:monitored → :approved`, `:available → :available`, `:held → :held`) covers every case, so
each target section renders `<CinderWeb.BookComponents.book_state_badge kind={target.media_kind}
state={book_badge_state(nil, target.status)} />` — the identical badge `BookDiscoveryLive` and
`DiscoverLive` already render, not a new badge kind or a new `badge_spec/2` clause.

**The manual-search-and-Grab affordance is gated to exactly one condition:**
`target.media_kind == :ebook and target.status == :monitored and Books.Grabs.for_target(target.id) == nil`.
Each clause has a specific reason, not a generic "looks right" gate:

- `media_kind == :ebook` — `Download.grab_book_target/2` itself refuses any other kind with
  `{:error, :unsupported_media_kind}` (`lib/cinder/download.ex:211`; audiobooks are B7). Gating in
  the UI means that atom is defense-in-depth, never a user-visible error.
- `status == :monitored` — the only state B4c acts on. An `:available` target already has a file;
  offering a second search there is the roadmap's own "Find a better match... only after initial
  acquisition is stable" upgrade path, and it names that as **B5** work, not B4. A `:held` target's
  only correct next action is clearing the hold — also **B5** ("blocklist clearing"). An
  `:unmonitored` target has nothing armed to grab against.
- `Books.Grabs.for_target(target.id) == nil` — a target stays `:monitored` for its *entire*
  download (no `:downloading` state exists — B4b §1), so `status == :monitored` alone cannot tell
  "nothing picked yet" from "downloading right now". A `BookGrab` row is the only place that
  distinguishes them. Read-only: this is a `Repo` read through the existing public
  `Books.Grabs.for_target/1`, not a write, so it needs no choke-point.

When a grab exists, the page renders an **in-flight download section** in place of the search
panel — see [§8](#8-live-updates) for what it reuses. This also means the write-side double-grab
guard (`book_grabs_book_target_id_index` unique index, and `reconcile_matching_intent/4`'s
release-equality check returning `{:error, :download_intent_busy}` for a second, different
release) is never the thing standing between an operator and a confusing error: the UI removes the
second Grab button before the guard would ever fire.

**`/library` books tab: deferred, not shipped here.** Argued both ways:

*For shipping it now:* B3b's own amendment framed the missing tab as blocked purely on data —
"nothing can appear in a books library listing until B4 imports a `book_files` row" — and B4b now
imports one. The roadmap's B4 Done-when literally says "shown as Available".

*Against shipping it now:* `library_live.ex` is not a generic listing shell waiting for a third
tab; it is ~500 lines of movies/TV-specific state — `tab: :movies | :tv` threaded through
`mount/3`, `library_path/2`, per-tab `assign_movies`/`assign_series`, a delete-with-file
confirmation flow, and sort keys (`size`, `added`, `title`) computed from video-file metadata that
has no obvious books analogue (a book's "size" is a `book_files.size` on a *different* schema
shape, and "delete" would need its own `book_files` semantics `library_live.ex` has never
expressed). A third tab is a change of the same order as B2a/B2b or B3a/B3b — its own reviewable
unit — not a few lines appended to an existing one. And **the Done-when criterion is already met
without it**: `book_badge_state/2` already renders `:available` on both surfaces that show book
state today — `DiscoverLive` (`lib/cinder_web/live/discover_live.ex:376-380`) and
`BookDiscoveryLive` (`lib/cinder_web/live/book_discovery_live.ex:264-269`), both shipped in B3b —
and the `/books/:id` page this slice adds shows the same status badge as its own pipeline view.
"Shown as Available" does not require a *third* surface; it requires that the two that exist
(plus this slice's new one) actually reach `:available`, which is exactly what wiring Grab does.

**Recommendation: defer.** A `/library` books tab belongs with B5, which already owns
Wanted/Missing and general books operational surfaces — a natural home for a listing view — rather
than being bolted onto this slice's scope under time pressure. This is a plan decision, not a
silent cut: flagging it here means it will not be forgotten, the way B3b's amendment flagged this
exact dependency for B4.

### 2. Reachability: how an admin reaches `/books/:id`

The first draft of this plan left the page's entry point unspecified — a typed URL is not a
surface, and B4's Book MVP gate is "an admin can acquire and import end to end", which an
unreachable page does not meet. Checked every admin surface that could plausibly link to a
per-title pipeline page:

- **`library_live.ex`** — links `/movies/:id` and `/series/:id` from its movie/TV cards
  (`library_live.ex:395,497`). Not usable: the books tab that would carry an equivalent link is
  deferred to B5 ([§1](#1-scope)).
- **`activity_live.ex`** — links `/movies/:id` from its movie-pipeline cards
  (`activity_live.ex:465`) and shows TV grabs. It is built entirely on `Catalog.list_movies/0` and
  the video `grabs` table (`activity_live.ex:1-42`) with no book concept at all. Extending it would
  mean giving it a second, `book_grabs`-shaped feed — a change of a different order than a link,
  and squarely B5's "operations" territory ("health for... book roots" and the general books
  operational surfaces already named there). Out of scope here, not silently invented.
- **`requests_live.ex`** — checked first as the most likely candidate, since it is the admin's
  queue for exactly the approval action that creates a `book_targets` row. **It links nowhere**:
  every request row (movie, series, *and* book alike) renders `request_title(r, @locale)` as plain
  text with no `<.link navigate=...>` at all (`requests_live.ex:409-412`). There is no existing
  per-request-row link to mirror, for any target type — the "equivalent" the earlier draft assumed
  exists does not.

**Decision:** add one. `RequestsLive` gets its first per-row detail link, scoped to books only —
adding it to movie/series rows too would be an unrequested change to code this slice has no
reason to touch. When `r.target_type == "book" and r.status == :approved` (the only state in
which `Requests.approve_request/3` has already created the `book_targets` row), the title wraps in
`<.link navigate={~p"/books/#{r.target_id}"} class="link link-hover">` — `r.target_id` is the
work's own id for a book request (locked by B3a's correction: `target_id: <book_works.id>`), and
`link link-hover` matches the exact class `library_live.ex`/`activity_live.ex` already use for a
title that navigates to its detail page, so this introduces no new visual idiom. A pending or
denied book request renders its title as plain text still — there is nothing at `/books/:id` for
it to reach yet.

### 3. Mount and param safety

Mirrors `movie_detail_live.ex:36-39` and `series_detail_live.ex:23-26` exactly — both guard
`Integer.parse/1` before ever handing the client-controlled `:id` param to `Repo.get` (a
non-integer segment must not raise `Ecto.Query.CastError`), and treat "parsed but not found" the
same as "malformed":

```elixir
def mount(%{"id" => id}, _session, socket) do
  with {id, ""} <- Integer.parse(id),
       %Work{} = work <- Books.get_work(id) do
    # ...
  else
    _ ->
      {:ok,
       socket
       |> put_flash(:error, gettext("That book couldn't be found."))
       |> push_navigate(to: ~p"/requests")}
  end
end
```

No new failure mode this slice has to invent: a non-integer id, a deleted/never-existed work id,
and a work id that legitimately exists but was never requested (reachable only by a stale
bookmark, since [§2](#2-reachability-how-an-admin-reaches-booksid) is the only real entry point and
never links to an unapproved work) all fall through the same `else` branch to the same redirect —
never a 500, never an unhandled `Ecto.NoResultsError`.

### 4. The manual-search panel: a new component, not a bolt-on

Movies and TV share `CinderWeb.ManualSearchComponent`
(`lib/cinder_web/components/manual_search_component.ex`, 465 lines). It is **not reused** here:
book candidates have a different data shape, and every non-trivial internal of that component is
video-specific.

- **Data shape.** The component's `results:` assign is one flat `[{release, verdict}]` list where
  `verdict` is `:ok | {:rejected, reason}`, built by folding a scorer sweep at render time.
  `Acquisition.Books.candidates/2` already returns the *partitioned* answer —
  `%{accepted: [{release, evidence}], rejected: [{release, reason}], complete?: bool}` — ranked
  inside `accepted`. Flattening that back into one undifferentiated list to fit the existing
  component's shape would throw away work `BookScorer.evaluate_all/3` already did and would still
  have to reconstruct a "why is this row visually separated" split by hand for
  [§6](#6-the-acceptedrejected-split).
- **Every non-async internal is video-only.** `search_context/1` bakes in anime-policy resolution
  and a TV `season_number`; `search_opts/2` builds movie/TV-only scorer options (resolution/source
  preference, TV pack episode counts); `language_states/4` and its ~80 lines of commentary walk
  `Language.filter/4` and `Acquisition.title_guard/3` — both video-only pool functions with no
  book equivalent (books have no `preferred_language`/`original_language` columns on any schema
  today — see [§7](#7-grab-wiring)); `grab_click/3` special-cases `%Movie{status: :available}` for
  the replace-confirm; `verdict_reason/1` is a dictionary of video rejection atoms
  (`:wrong_resolution`, `:contradictory_subtitles`, `:awaiting_preferred_group`, …) with zero
  overlap against the book scorer's own atom set (`:format_unknown`, `:author_mismatch`,
  `:abridged_edition`, …).
- Threading a book branch through all of that would mean a `mode: :book` conditional in nearly
  every clause for a component whose only genuinely shared logic is the async-fetch/grab-forward
  skeleton described in [§5](#5-where-the-search-runs) — the "forced reuse that needs media-kind
  conditionals threaded through it" the assignment warns against.

**What *is* reused is the pattern, exactly:** a `live_component` that runs the search with
`start_async`/`handle_async`, forwards a chosen release to its parent LiveView with
`send(self(), {:manual_grab, ...})` rather than writing anything itself, and renders `:loading`,
`:error`, and `:loaded` states. `CinderWeb.BookManualSearchComponent`
(`lib/cinder_web/components/book_manual_search_component.ex`) copies that skeleton and is book-
native everywhere else: it takes `target` (a `%BookTarget{}` with `work` preloaded) and `work` (the
fully-preloaded `%Cinder.Books.Work{}` `candidates/2` wants), calls
`Acquisition.Books.candidates(work, protocols: Download.available_protocols())`, and renders
format/language/retail/size badges from the evidence map `BookScorer.evaluate/3` already returns
(`format`, `formats`, `language`, `retail?`, `size`, `query_origins`) rather than reverse-engineering
them from a release struct. It sends `{:manual_grab, :book, target, release}` on Grab, matching the
existing three-tuple-plus-mode idiom `movie_detail_live.ex`/`series_detail_live.ex` already read
off `handle_info`.

No replace-confirm: B4c never offers Grab on an `:available` target ([§1](#1-scope)), so the
`ask_replace`/`confirm_action` half of the existing component (which exists solely for that case)
has nothing to do here and is not ported.

**Accessibility.** The Grab button carries visible text ("Grab"), matching every existing Grab
button in the codebase — no icon-only control is introduced here. Every new user-facing string
(row copy, empty states, banners) goes through `gettext`, matching the rest of `lib/cinder_web`.

### 5. Where the search runs

Mirrors the existing component exactly: `start_async(socket, :search, fn -> Acquisition.Books.candidates(work, opts) end)`
on first connected render, a `:loading` spinner (`gettext("Searching releases…")`, unchanged
copy) until `handle_async(:search, {:ok, result}, socket)` assigns `:loaded`, and an `:error` state
on `{:error, reason}` (`Books.candidates/2`'s only error path — every query failed) or task exit.

**Cancellation on navigate-away needs no new code.** `start_async` tasks are supervised under the
LiveView process that started them (Phoenix's `Phoenix.LiveView.AsyncResult`/`Task.Supervisor`
wiring), so when an operator navigates off `/books/:id` the LiveView process terminates and the
in-flight indexer task is torn down with it — the same guarantee `ManualSearchComponent` already
relies on for movies/TV, unstated because it has never needed restating.

**No restart-on-context-change complexity.** `ManualSearchComponent` rebuilds a `search_context`
tuple and cancels/restarts the async fetch because its target/season/profile/anime-policy can all
change while the panel stays mounted (switching seasons on `/series/:id`, a profile reassignment).
`/books/:id` has exactly one target per media kind and no season selector — the work and target
are fixed for the life of the mount (an admin editing the profile is not part of this slice; see
[§10](#10-what-stays-out)) — so `BookManualSearchComponent` runs the search once per panel-open and
needs no context-diffing at all. This is a real simplification, not a gap: the one axis that
*would* invalidate a stale result — the target leaving `:monitored` mid-search — is already
covered structurally, because the panel is unmounted (its `:if={...}` in
[§1](#1-scope)'s gate goes false) the moment a `{:book_target_updated, ...}` broadcast changes
`target.status`.

### 6. The accepted/rejected split

Both lists render, always — this is the point of `evaluate_all/3` returning two lists rather than
one filtered one, and the roadmap's "rejected with deterministic reasons" is explicitly an
operator-facing legibility requirement, not a debugging log.

**The rejection-copy dictionary is derived from one canonical list, not transcribed by hand.**
`Cinder.Acquisition.BookScorer` collapses what would otherwise be two hand-maintained copies of
the same 12 atoms — the closed `@type reason` union and a runtime-introspectable accessor — onto
one `@reasons` module attribute the type is itself generated from:

```elixir
@reasons [
  :format_unknown,
  :format_rejected,
  :author_mismatch,
  :title_mismatch,
  :collection_ambiguous,
  :language_mismatch,
  :wrong_protocol,
  :title_unfoldable,
  :abridged_edition,
  :format_contradictory,
  :size_out_of_band,
  :blocked_term
]

@type reason :: unquote(Enum.reduce(@reasons, &{:|, [], [&1, &2]}))
```

A `@type` is not runtime-introspectable even when generated this way, so `BookScorer.reasons/0`
(mirroring the module's existing `accepted_formats/0`/`size_band/0` introspection functions)
returns `@reasons` directly. A reason added to `evaluate/3` and forgotten in `@reasons` now
changes both the type `evaluate/3`'s own `@spec` is checked against and what `reasons/0` returns
— one place to add it, not two kept in sync by hand.

`BookManualSearchComponent` gets one `gettext`'d clause per atom in `BookScorer.reasons/0` — no
stringify fallback (`to_string(reason)`/`inspect(reason)`) rendered to a user anywhere:

| Atom | Copy |
|---|---|
| `:format_unknown` | "unrecognized format" |
| `:format_rejected` | "format not accepted" |
| `:format_contradictory` | "contradictory format claims" |
| `:author_mismatch` | "author doesn't match" |
| `:title_mismatch` | "title doesn't match" |
| `:title_unfoldable` | "title doesn't match" |
| `:language_mismatch` | "language doesn't match" |
| `:size_out_of_band` | "outside expected size" |
| `:blocked_term` | "contains a blocked term" |
| `:collection_ambiguous` | "omnibus/collection, not this work" |
| `:abridged_edition` | "abridged edition" |
| `:wrong_protocol` | "no client for protocol" |

An atom outside this set can only reach the render function if `BookScorer` grows a new reason and
this table is not updated in the same change — the failure mode the review flagged as
unacceptable. Rather than a silent stringify fallback OR an unhandled `FunctionClauseError`
crashing the whole LiveView over one release row, the render function's **last** clause is an
explicit, logged, non-leaking fallback: `Logger.warning("book manual search: unrecognized
rejection reason #{inspect(reason)}")` then `gettext("rejected")` — visible to whoever ships the
change, never a raw atom rendered to an operator. [§11](#11-test-plan) makes the "every real reason
has real copy, and copy is never the atom's own name" property a test, driven off
`BookScorer.reasons/0` so it cannot go stale either.

Remaining behavior, unchanged from the first draft:

- **Accepted** (`result.accepted`, already ranked best-first): one row per release with a Grab
  button, showing format, language (or "untagged"), a `retail` badge when true, and size.
- **Rejected** (`result.rejected`): one row per release with its title and the mapped reason above.
  No Grab button — nothing overrides a rejection here (unlike the movie/TV panel, which lets an
  operator override a policy/quality verdict on a rejected row; the book scorer's rejections are
  identity and format facts, not preference ones, so there is no "grab anyway" the roadmap's
  fail-closed design intends to allow).
- **Both empty** (`accepted == [] and rejected == [] and complete? == true`): "No releases found."
  — a genuine zero-result search.
- **`complete? == false`**: a distinct banner above whatever *did* come back — "Some indexers
  could not be reached; results may be incomplete." — rendered whenever `complete?` is false,
  independent of whether either list is empty. This is the B0-mandated distinction between "we
  looked and found nothing" and "we did not fully look": collapsing them would make a five-second
  indexer timeout look identical to a genuinely absent release, which is exactly the failure mode
  `Acquisition.Books.search/1`'s docstring calls out.
- **`{:error, reason}`** (every query failed): the existing `:error` treatment — "Couldn't reach
  the indexer. Try again." with a retry affordance, not a lower-fidelity variant of the
  `complete? == false` case (that one still has a real, if partial, result to show).

### 7. Grab wiring

`Download.grab_book_target/2`, read at `lib/cinder/download.ex:198-211`:

```elixir
def grab_book_target(%BookTarget{media_kind: :ebook} = target, %BookRelease{} = release)
def grab_book_target(%BookTarget{}, %BookRelease{}), do: {:error, :unsupported_media_kind}
```

No `@spec` — `download.ex` carries none anywhere in its 1,190 lines (a `@doc` only, on every
public function, is the file's actual convention), so this doc does not invent a lone typespec
for one function to make a quote easier to write; the return contract is instead the prose and
the outcome table below, which is exhaustive already.

(Confirmed against `test/cinder/download/book_intent_test.exs`, which asserts
`{:ok, %BookGrab{}} = Download.grab_book_target(...)` on success — not an `%Intent{}`; the intent
is an implementation detail `reconcile_intent/1` consumes and deletes on the way to producing the
grab row.)

Takes the `%BookRelease{}` straight from a `BookManualSearchComponent` accepted row — no
conversion needed on the caller's side; `Download` converts it to the client-facing `%Release{}`
internally (`book_release/1`, `download.ex:216-223`). Unlike `grab_movie/2`, it needs no
`ensure_policy_marker/2` call first (no anime policy exists for books).

**It is a synchronous call that makes a real download-client request in the request path.**
`reserve_and_reconcile/4` → `reconcile_intent/1` → `do_reconcile_valid_intent/1` calls
`do_submit_intent/1` inline when `remote_id` is `nil` (`download.ex:374-376`) — the same behavior
`grab_movie/2` and `grab_episodes/2` already have today. This is not a new concern for B4c: the
existing `handle_info({:manual_grab, :movie, ...})` idiom already accepts this synchronous beat
(covered client-side by the existing `phx-disable-with={gettext("Grabbing…")}` on the Grab
button), so `handle_info({:manual_grab, :book, target, release}, socket)` on `BookDetailLive`
mirrors it exactly:

```elixir
def handle_info({:manual_grab, :book, %BookTarget{id: target_id} = target, release}, socket) do
  outcome = Download.grab_book_target(target, release)
  socket = socket |> assign(:searching?, nil) |> reload()
  {level, msg} = book_grab_flash(outcome, socket, target_id)
  {:noreply, put_flash(socket, level, msg)}
end
```

`reload/1` re-reads the work (and its grabs) before `book_grab_flash/3` runs, not after: the
catch-all error clause below reads the target's *post-grab* state, so the reload has to have
already happened.

Outcome rendering — every reachable atom, not a catch-all (atoms confirmed against
`test/cinder/download/book_intent_test.exs`):

| Result | Flash |
|---|---|
| `{:ok, %BookGrab{}}` | info: "Grabbing the selected release…" (matches movie/TV copy) |
| `{:error, :download_intent_busy}` | error: "This target already has a download in progress." (should not be reachable given the [§1](#1-scope) gate, but is the honest race: the poller or another admin tab could win between render and click; also the exact outcome of retrying a Grab click, since it is not idempotent client-side) |
| `{:error, :bad_torrent}` / other `@permanent_submission_errors` (`download.ex:24-29`) | error: the target's own `hold_reason` — `grab_book_target/2` already parks the target `:held` synchronously in this case (proven by `book_intent_test.exs`'s "the target lands `:held`..." case), so the flash can read the fresh `hold_reason` straight back rather than inventing separate copy |
| `{:error, :unsupported_media_kind}` | error: generic fallback copy — unreachable in practice given the `:ebook`-only gate, never surfaced as a raw atom |
| `{:error, %Ecto.Changeset{}}` / any other atom | error: generic "Couldn't submit this release. Try again." — the same unclassified-failure fallback the movie panel uses today |

No status write happens here beyond what `grab_book_target/2` already performs internally
(creating the `book_grabs` row through `Cinder.Books.Grabs` inside `reconcile_intent`'s book
clause) — `BookDetailLive` calls exactly one `Cinder.Download` function and writes nothing to
`Repo` itself, matching the "a LiveView writes none of them directly" constraint.

### 8. Live updates

**Terminal transitions are already covered by the existing broadcast.** `Books.subscribe_targets/0`
delivers `{:book_target_updated, target}`, and every terminal write already broadcasts on it:
`Books.hold_target/2` (→ `:held`, called from both `Download` on a permanently rejected submission
and `BookPoller` on a dead download or refused payload) and `Cinder.Books.Files.record_import/3`
(→ `:available`, `lib/cinder/books/files.ex:110-117`). `BookDetailLive` subscribes in `mount/3`
when `connected?/1`, and a catch-all `handle_info({:book_target_updated, target}, socket)` that
reloads the work (`Books.get_work(socket.assigns.work.id)`) when `target.work_id` matches, no-ops
otherwise — the same idiom `book_discovery_live.ex:117-124` already uses for exactly this
broadcast.

**In-flight progress broadcasts too — decided, not merely proposed.** `Cinder.Books.Grabs.track/2`
(called every `BookPoller` tick from `advance_downloading`) writes `download_progress`/
`download_speed`/`download_eta` to the `book_grabs` row and, as shipped in B4b, **broadcasts
nothing** — a defect measured against its own video sibling,
`Cinder.Catalog.Grabs.update_grab_download_metrics/2`, which broadcasts
`Cinder.Catalog.broadcast_series/1` on every real write specifically so `/movies/:id` and
`/series/:id` render a live percentage bar. The first draft of this plan proposed routing around
it with a LiveView-owned polling timer; that was wrong on both counts it was argued on:

- **House style.** AGENTS.md and every existing detail page use one live-update idiom —
  subscribe, re-render on broadcast. A second, timer-driven mechanism on one page is the "second
  convention beside an existing one" the repo's conventions forbid, not a harmless local
  simplification.
- **Cost.** A broadcast fires only when the poller's write actually changes something; a client
  timer re-queries the DB on a fixed interval regardless of whether anything moved, for every open
  tab. The polling design was *more* standing work, not less.

**Fix:** `Cinder.Books.Grabs.track/2` gets a post-write broadcast, placed exactly where
`update_grab_download_metrics/2` places its own — after the commit, and **only when the write
actually changed something** (mirroring that function's `if changes == %{} do ... else ... end`
branch at `lib/cinder/catalog/grabs.ex:214-246`, so a poller tick that re-reports an identical
progress snapshot does not broadcast a no-op to every open `/books/:id` tab). The message is
`{:book_grab_updated, grab}` on the existing `book_targets` PubSub topic — no new topic, since
every current subscriber (`BookDetailLive`, and any future one) already subscribes there via
`Books.subscribe_targets/0`. `BookDetailLive` gets one more `handle_info` clause matching it,
scoped to the mounted work's target(s) the same way the `:book_target_updated` clause already is.

**Rendering reuses the shared progress UI, not new markup.** `CinderWeb.CoreComponents.status_badge/1`
already renders an accessible in-flight indicator — `role="status"`, a native `<progress>` element
with `aria-label`, a textual percentage, and a speed/ETA line, never colour alone
(`core_components.ex:673-697`) — and its `:grab` vocabulary (`badge_spec(:grab, :downloading)` →
"Downloading", `badge_spec(:grab, :downloaded)` → "Importing") is already generic, not
movie/episode-specific. The in-flight section is:

```heex
<.status_badge
  kind={:grab}
  status={if @grab.content_path, do: :downloaded, else: :downloading}
  progress={@grab.download_progress}
  speed={@grab.download_speed}
  eta={@grab.download_eta}
/>
```

No new component, no new `badge_spec/2` clause, and the accessibility properties the review asked
for come from code this page did not have to write.

### 9. Gating

`/books/:id` goes in the existing `:admin` live_session (`router.ex:101-125`), immediately after
`live "/series/:id", SeriesDetailLive` — the same session every other pipeline-detail page
(`/movies/:id`, `/series/:id`) already lives in, with the same `on_mount` stack (locale,
authenticated, active, **require_admin**, setup, current path, badges). Confirmed correct: this
page exposes indexer query results, release download URLs (indirectly, via the Grab action), and
the household's acquisition pipeline state for a title — the same sensitivity class as
`/movies/:id`, not the request-only sensitivity of `/book/:provider/:foreign_id`, which lives in
`:authenticated` and is deliberately readable by any household member requesting a title.

A non-admin who reaches the route (typed URL, stale bookmark) gets exactly what `/movies/:id`
already gives them: `UserAuth.on_mount(:require_admin, ...)` halts the mount, flashes "You don't
have access to that page.", and redirects to `/` (`lib/cinder_web/user_auth.ex:297-308`) — no new
gating code, the existing `live_session` entry is sufficient.

### 10. What stays out

- **Automatic selection stays unreachable.** B4c adds a UI *caller* for `candidates/2`; it adds no
  new *automatic-selection* code path to `Cinder.Acquisition.Books` or
  `Cinder.Acquisition.BookScorer` (it does add `BookScorer.reasons/0`, an introspection accessor
  with no selection logic — see [§6](#6-the-acceptedrejected-split)). There is still no
  `best_book_release/2`, and `BookPoller` still runs its two passes with no search pass
  (`download/book_poller.ex:66-73`) — nothing in this slice changes that file.
- **Audiobooks** render read-only in the per-work pipeline view ([§1](#1-scope)): a status badge,
  a hold reason if held, no search entry point, no Grab. `grab_book_target/2`'s
  `{:error, :unsupported_media_kind}` clause exists for exactly this target shape and is never
  exercised by this UI because the UI never offers the action.
- **`/activity` stays movies/TV-only** ([§2](#2-reachability-how-an-admin-reaches-booksid)) — no
  `book_grabs` feed is added there.
- **B5's Wanted/Missing, author monitoring policies, retry, and blocklist-clearing** are untouched
  — this slice ships no "pause/resume", "retry", or "clear hold" control. A `:held` target shows
  its
  `hold_reason` and nothing else actionable.
- **B6 adoption/migration** is untouched; nothing here reads or writes Bookshelf-sourced data.
- **The two B3b orphans stay parked.** Author aliases and operator metadata overrides were handed
  to "whichever milestone first ships an edit control"
  (`docs/plans/2026-08-20-readarr-replacement-roadmap.md:335-338`). B4c ships **no** edit
  control — the manual-search panel is an *acquisition* action (pick a release, submit a
  download), not a metadata correction to the work/edition/author catalog. Neither orphan gets a
  caller here; they remain explicitly unclaimed for a future milestone (most likely B5, where
  author-monitoring policy work gives author aliases a real caller — local author search — for
  the first time).

### 11. Test plan

New: `test/cinder_web/live/book_detail_live_test.exs`,
`test/cinder_web/components/book_manual_search_component_test.exs`. Both use
`Cinder.DataCase`/`CinderWeb.ConnCase` and `Mox` exactly like the existing B4a/B4b/B3b suites
(`test/cinder/acquisition/books_test.exs`, `test/cinder/download/book_intent_test.exs`,
`test/cinder_web/live/book_discovery_live_test.exs`) — `Cinder.Acquisition.IndexerMock` for
`search_book`/`search_book_query`, and `Cinder.Download.ClientMock` (the existing torrent-client
mock `book_intent_test.exs` already drives through `grab_book_target/2` for `:add`/
`:find_by_operation_key`) for the client calls `grab_book_target/2` triggers synchronously. No
test hits the network — every external call resolves through `Application.fetch_env!/2` to its
Mox mock, per AGENTS.md.

**`BookDetailLiveTest`:**

- Gating: a non-admin session redirected from `/books/:id` with the standard flash.
- Param safety: a non-integer `:id`, and an integer `:id` with no `book_works` row, both redirect
  to `/requests` with the "couldn't be found" flash rather than crashing.
- Renders a work with no targets at all (pending/denied request) — no pipeline section, no crash.
- Renders a `:monitored` `:ebook` target with the search panel available, and an `:audiobook`
  target (if present) read-only with no search affordance.
- Renders an `:available` target with no search panel and no Grab button.
- Renders a `:held` target with its `hold_reason` and no search panel.
- Grab success: `IndexerMock` returns one accepted release,
  `Cinder.Download.ClientMock` accepts `:add`/`:find_by_operation_key`, click Grab, assert the
  info flash and that `Books.Grabs.for_target/1` now returns a grab — and that the search panel
  is replaced by the in-flight section on next render.
- Grab failure paths: `Cinder.Download.ClientMock` returns `{:error, :bad_torrent}` (a permanent
  submission error, `book_intent_test.exs`'s own fixture) → assert the target reaches `:held`
  synchronously with the flash rendering that `hold_reason`; a non-permanent client error (e.g.
  `{:error, :qbittorrent_down}`) → assert the target *stays* `:monitored` (the retry-backoff path
  is `BookPoller`'s, untouched by this slice) and the flash renders the generic failure copy, not
  a raw atom.
- `{:book_target_updated, target}` broadcast while mounted (simulate via `Books.hold_target/2` or
  `Books.Files.record_import/3` in the test) reloads the page's badge without a manual refresh.
- `{:book_grab_updated, grab}` broadcast while mounted (simulate via `Books.Grabs.track/2` in the
  test) updates the rendered progress percentage without a manual refresh, and a `track/2` call
  whose attrs produce no real change does **not** re-broadcast (assert via a process mailbox
  count, mirroring how `Catalog.Grabs`' own no-op branch would be tested).
- `RequestsLive`: an approved book request row renders a `link link-hover` to `/books/#{work_id}`;
  a pending or denied book request row does not.

**`BookManualSearchComponentTest`:**

- A preseeded `results:`-equivalent (candidates map) path, mirroring
  `manual_search_component_test.exs`'s `render_panel/1` helper, asserting accepted rows show
  format/language/retail/size and rejected rows show their mapped reason text.
- **Exhaustiveness, driven off `BookScorer.reasons/0`**: for every atom in
  `BookScorer.reasons/0`, render a rejected row carrying it and assert the rendered text (a) is
  non-empty, (b) is not `Atom.to_string(reason)`, and (c) is not the same across two different
  atoms (catches a copy-paste clause that renders the wrong string for the right atom, not just a
  missing one). A row with a reason *outside* `BookScorer.reasons/0` renders the generic fallback
  string, never the atom's own name — proving the failure mode the review named ("a
  `to_string`-of-unknown-atom fallback rendering `:format_unknown` at a user") cannot occur for
  either a known or an unknown atom.
- `complete?: false` renders the incomplete-search banner even when `accepted` is non-empty.
- Empty accepted and rejected with `complete?: true` renders "No releases found."; the
  `{:error, reason}` path (via a host LiveView driving the real async fetch, mirroring
  `ManualSearchHostLive`) renders "Couldn't reach the indexer. Try again."
- Clicking Grab on an accepted row sends `{:manual_grab, :book, target, release}` to the parent,
  asserted via a small host LiveView the same way `ManualSearchHostLive` proves the movie/TV grab
  forward today.
- No Grab affordance renders on a rejected row.

## Done when

- An admin can reach `/books/:id` from an approved book request in `/requests`, see the indexer's
  accepted and rejected candidates with reasons, press Grab, and watch the target reach
  `:available` (file imported) or `:held` (exact reason shown) without a page reload.
- In-flight download progress updates live, driven by a real `Cinder.Books.Grabs.track/2`
  broadcast, not a client-side poll.
- `complete?: false` and a genuinely empty result render distinguishably.
- Every `BookScorer.reasons/0` atom renders real, distinct, `gettext`'d copy; no unknown atom can
  reach the DOM as its own name.
- The search/Grab affordance is unreachable for an `:audiobook` target, an `:available` target, a
  `:held` target, or a target with an in-flight `BookGrab` already present.
- A malformed or nonexistent `/books/:id` redirects with a flash, never crashes.
- No new caller reaches `best_book_release/2` (it still does not exist) or gives `BookPoller` a
  search pass.
- A non-admin session cannot reach `/books/:id`.
- `mix test` is green.

## Amendments from review

Recorded here rather than silently folded in, per the B4a/B4b convention.

- **§8 (live updates) reversed from its first draft.** The plan originally proposed a LiveView-
  owned polling timer to paper over `Cinder.Books.Grabs.track/2` broadcasting nothing, to avoid
  touching B4b's already-reviewed module. Review rejected this: it stands up a second live-update
  convention beside the subscribe-and-re-render idiom every other detail page uses, and a fixed
  timer that re-queries regardless of change is *more* standing cost than a broadcast that only
  fires on a real write, not less. The plan now fixes the actual defect at its source —
  `Cinder.Books.Grabs.track/2` broadcasts `{:book_grab_updated, grab}` on real change only,
  mirroring `Cinder.Catalog.Grabs.update_grab_download_metrics/2`'s own no-op guard.
- **§2 (reachability) added; it did not exist in the first draft.** The plan specified the page's
  design but never said how an operator reaches it. Checked `library_live.ex` (the tab is
  deferred), `activity_live.ex` (video-only, no book concept, out of scope), and `requests_live.ex`
  (found, surprisingly, that **no** request row — movie, series, or book — links anywhere today, so
  there was no existing per-request link to mirror). Added the first such link, scoped to approved
  book rows only.
- **§3 (mount/param safety) added.** The first draft never specified `/books/:id`'s behavior for a
  malformed or nonexistent id. Now mirrors `movie_detail_live.ex`/`series_detail_live.ex`'s
  `Integer.parse/1`-then-lookup guard exactly.
- **§6 (accepted/rejected split) copy dictionary is now derived, not transcribed.** Added
  `BookScorer.reasons/0` (mirroring the module's existing `accepted_formats/0`/`size_band/0`
  introspection functions) as the single source of truth for which rejection atoms exist, and made
  "every reason renders real copy, no unknown atom leaks to the DOM" a test driven off that
  function rather than a hand-maintained list in two places.
- **§1's badge rendering simplified.** The first draft did not specify how the target status badge
  itself would render. It now reuses `CinderWeb.BookComponents.book_state_badge/1` — the exact
  component `BookDiscoveryLive`/`DiscoverLive` already ship — fed through
  `book_badge_state(nil, target.status)`, rather than inventing new badge markup.
- **§8's progress indicator reuses `CinderWeb.CoreComponents.status_badge/1`'s `:grab` vocabulary**
  instead of new markup, which is also how the review's accessibility requirement (no colour-only
  state, `aria-label`led progress) is met without writing new accessible markup from scratch.
- **Implementation found `Cinder.Books.Grabs`'s own moduledoc had pre-empted this exact fix — and
  was wrong about it once B4c existed.** Before this slice, the module's moduledoc read "the rows
  are transient state, not catalog state, so — unlike a target transition — none of these
  broadcast: the target's own status write is what open views react to." That was a true, deliberate
  B4b design choice at the time: nothing consumed `book_grabs` progress live, so nothing needed to
  react to it. It stopped being true the moment this slice gave the row a reader. The moduledoc now
  says which of the module's five writes still don't broadcast (`create`, `mark_downloaded`,
  `bump_attempts`, `delete` — each sits next to a target-status write elsewhere that does) and names
  `track/2` as the one exception, rather than leaving a blanket claim the code no longer supports.
- **§7's Grab-outcome table is honored by *reading state back*, not by matching
  `Cinder.Download`'s private error-atom list.** The table in §7 above enumerates
  `:download_intent_busy`, the permanent-submission-error family, `:unsupported_media_kind`, and a
  generic changeset fallback as if each needed its own clause. Implementing it that way would have
  required either duplicating `Cinder.Download`'s private `@permanent_submission_errors` list in
  `BookDetailLive` (a second copy of a fact one module already owns, guaranteed to drift) or
  exporting it. Instead, `book_grab_flash/3`'s catch-all clause re-reads the target's own
  post-grab status off the just-`reload/1`ed work: if it is `:held`, the flash is that target's own
  fresh `hold_reason` (produced by whichever atom `grab_book_target/2` actually returned); if not,
  it's the generic fallback. This renders the *observable outcome* rather than reimplementing
  `Download`'s classification, and needs no update if that private list ever changes.
- **Fifteen new `gettext` strings needed manual French translation** (`mix gettext.extract --merge`
  only extracts and merges the *msgid*s; `test/cinder_web/translations_complete_test.exs` requires
  every one non-empty and non-fuzzy in `fr/LC_MESSAGES/default.po`). Two pre-existing short English
  strings this slice reused (`"retail"`, `"contradictory format claims"`) fuzzy-matched onto
  unrelated existing French translations ("Détails", "audio contradictoire") during the merge and
  needed correcting, not just filling in — a fuzzy match is gettext's best guess, not a review.
- **Test fixtures needed a title that doesn't embed the test's unique-id suffix.** The first pass of
  `book_detail_live_test.exs`'s grab-flow tests built each work as `"The Dispossessed #{id}"` (the
  same idiom every other books test in this codebase uses for uniqueness) but then searched for
  release names that named only `"The Dispossessed"` — the scorer's title-remainder rule correctly
  rejected every one as `:title_mismatch`, since the numeric suffix is an unrecognized leftover
  token. Tests that exercise real scoring pass a fixed `title:` instead; tests that don't touch the
  scorer keep the unique-suffixed default.
- **`hold_reason` renders a raw atom, by pre-existing design — not a gap in the exhaustiveness
  guarantee.** `Cinder.Books.hold_target/2` stringifies an atom reason (`books.ex:214`,
  `Atom.to_string/1` — untouched by this slice), and the flash for a permanently rejected
  submission shows it verbatim. That is a *different* code path from the manual-search panel's "a
  rejection never renders as its own atom name" guarantee: the panel's reasons are
  `BookScorer.reasons/0`'s closed, adversarially-reachable set (an indexer result names the
  rejection), and are deliberately never shown as raw atoms. A `hold_reason` is an internal fact
  the pipeline itself produced (a client error atom, a content-policy verdict) —
  non-attacker-controlled and already the codebase's convention for the field elsewhere (`books.ex`
  itself: "the reason a household member reads renders the same way whichever half gave up"). The
  two are not in tension; a later reader should not "fix" `hold_reason` to match the panel's
  dictionary — they answer different questions. (`book_detail_live_test.exs`'s permanent-failure
  test asserts against the target's own freshly-read `hold_reason`, not a literal atom string, so
  the test does not itself encode which atom `grab_book_target/2` happens to return.)
- **`:unmonitored` renders an empty badge on this page — unreachable today, and B5's obligation
  once it stops being unreachable.** `book_badge_state(nil, :unmonitored)` falls through to
  `:none`, whose badge renders nothing. This slice never observes it: a `book_targets` row is only
  ever created at approval, already armed to `:monitored` in the same call
  (`Books.monitor_target/4`), and a target with no row at all renders "Not yet approved" — a
  different, handled case. But B5 owns the "pause/resume" control the roadmap names, and the
  first
  write that sets an existing, still-linked target back to `:unmonitored` will render a blank badge
  with no fallback text on `/books/:id`, `BookDiscoveryLive`, and `DiscoverLive` alike — all three
  share `book_badge_state/2`. Not fixed here: it has no caller that can reach the state yet, and the
  fix belongs in the shared helper, not in any one surface. Recorded as an explicit obligation on
  B5, the same way B3b handed `:held` and this route forward to B4.

### Second review round

Eight independent fresh-context reviews, three real defects and a set of should-fixes. Recorded
in the same voice, per the B4a/B4b convention of not silently folding a correction in.

- **BLOCKER, fixed: `BookManualSearchComponent`'s `"grab"` handler crashed on a `:results` that was
  never assigned.** `handle_event("grab", …)` dereferenced `socket.assigns.results.accepted`
  unconditionally, but `:results` was only ever set by `handle_async` or a preseed — a "grab"
  event arriving while `state` was `:loading` or `:error` raised `KeyError` and took the parent
  LiveView down with it, directly contradicting the component's own "ignore anything unmatched
  rather than crash" comment two lines below. `update/2` now assigns a safe empty default
  (`assign_new(:results, fn -> %{accepted: [], rejected: [], complete?: true} end)`) on the very
  first render, mirroring `ManualSearchComponent`'s own `results: []` default — the sibling never
  had this bug because it always initializes `results` alongside `state: :loading`, and this
  component didn't. §11 undersold this as a should-fix originally and it was not one.

  The first regression test written for this — a hand-built `%Socket{}` that already carried
  `:results` in its assigns, with `handle_event/3` called directly — **passed against the unfixed
  component**, proving nothing: `handle_event/3` is byte-for-byte unchanged by the fix, and the
  bug was `:results` being *absent*, which only ever happens through the real `update/2` control
  flow that test bypassed by construction. The corrected version calls the real `update/2` (a
  disconnected socket with no `transport_pid`, so `connected?/1` is false and `update/2` takes its
  dead-render branch, which pre-fix touched `:state` and never `:results`) and then
  `handle_event("grab", …)` on the socket that call actually produces. Verified in both
  directions: reverting the component to the pre-fix commit and running only this test raises the
  exact `KeyError` on `socket.assigns.results.accepted` the bug report described, with the file's
  other 11 tests unaffected; restoring the fix, all 12 pass again. Recording the failed first
  attempt here rather than only the corrected version, because a clean-looking claim that a test
  "proves the fix" is exactly the kind of unverified assertion this document exists to not make.
- **`Cinder.Books.Grabs.track/2`'s parity claim with `Cinder.Catalog.Grabs.update_grab_download_metrics/2`
  was false as written, fixed to be true.** The doc comment claimed the same guard without it: the
  video sibling refuses a write that would land on an already-`:downloading`-false grab
  (`is_nil(content_path)`, `{:error, :stale_grab}` on a miss) and drops a regressed
  `download_progress` from the write (`keep_progress_high_water/2`) rather than letting a client's
  brief under-report walk the operator-visible bar backwards; `track/2` had neither. Both gaps
  predate this slice (inherited from B4b's original `track/2`), but the new broadcast is what makes
  them user-visible for the first time — a progress bar that visibly regresses, and a metrics write
  silently landing on a grab the import phase already claimed. `track/2` now mirrors both guards
  exactly, bypassing `BookGrab.changeset/2` for a guarded `Repo.update_all` the same way
  `mark_downloaded/2` already does in this file, and replicates the "advance
  `download_progress_at` only on real forward motion" rule inline (the schema's own
  `advance_download_progress_at` no longer runs for this write, since `update_all` skips
  changesets). `@spec track/2`'s return type changed from `{:error, Ecto.Changeset.t()}` to
  `{:error, :stale_grab}` to match; `BookPoller.track_and_reap/2`'s `{:error, reason}` branch only
  logs `inspect(reason)`, so this is not a breaking change to its caller. Three new tests in
  `grabs_test.exs` cover the staleness refusal, the regression drop, and that a regression-only
  call (nothing else changed) still writes and broadcasts nothing.
- **Reversed: the `@spec` added to `grab_book_target/2` in this round is removed again.** The prior
  entry above recorded adding a real `@spec` so §7's quoted block would stop being aspirational.
  That was the wrong fix, and the instruction to add it was itself wrong — `download.ex` carries
  no `@spec` anywhere across 1,190 lines; a `@doc`-only convention is the actual, consistent
  pattern, and one lone typespec would have been a second, undiscussed convention introduced
  *because* a doc quoted code that didn't exist, not because the module wanted one. Adding it also
  had a real cost the first pass missed: two new lines shifted every downstream line number in the
  file, so four citations that were correct — `download.ex:211` (the `:unsupported_media_kind`
  clause), the `198-211` range on the quoted block, `book_release/1` at `216-223`, and
  `do_reconcile_valid_intent/1` calling `do_submit_intent/1` at `374-376` — went stale in the same
  commit that was supposed to close the drift class the `@spec` finding itself named. The `@spec`
  is gone; §7's fenced block now shows only the two real `def` clauses, with a line stating plainly
  that this file has no typespecs and that the return contract lives in the prose and the outcome
  table instead. All four citations were re-verified against the reverted file and are correct
  again on their own, not merely restored by assumption. The doc describes the code; a plan doc
  quoting something is never a reason to add it.
- **`BookScorer`'s `@type reason` and `reasons/0` were two hand-maintained copies of the same 12
  atoms, not one.** §6 said the opposite ("`reasons/0`... co-located with `@type reason`" implying
  one source) while the code carried two independent literals. Collapsed onto one `@reasons`
  module attribute the type is generated from (`@type reason ::
  unquote(Enum.reduce(@reasons, &{:|, [], [&1, &2]}))`), so a reason added to one and forgotten in
  the other is now structurally impossible rather than merely discouraged. The test that used to
  compare `reasons/0` against a *third* hand-copied list (proving nothing about `evaluate/3`'s
  real behavior, despite its own name claiming otherwise) is replaced with one that calls
  `evaluate/3` through a real, previously-verified fixture for every one of the 12 reasons and
  checks the fixture set is exactly `reasons/0` — an actual reachability proof, not a list
  comparison, in both directions.
- **Should-fixes, all applied:** `update/2`'s preseed branch now `cancel_async(:search)`s before
  assigning, closing a latent race where a caller that starts a connected search and then supplies
  `results:` could have the stale task's late completion clobber the preseed (unreachable from the
  current sole caller, matches `ManualSearchComponent`'s own `maybe_cancel_stale_search/2`
  idiom). `book_manual_search_component_test.exs` gained direct-invocation coverage for `:loading`
  and `:error` rendering and for `handle_async`'s three outcomes, none of which any test exercised
  before (every existing test drove the pre-seed path only). `book_detail_live_test.exs` gained a
  malformed-`target_id` test for the `manual_search` event, the same client-controlled-input
  contract already tested at mount.
- **Nits taken:** the not-found redirect now goes to `/requests` (this page's own back-link target)
  instead of `/`, matching every sibling detail view's convention of redirecting to its own list
  page rather than the global root. The permanent-failure test now asserts against the target's
  real, freshly-read `hold_reason` instead of the literal atom string `"bad_torrent"`. Fixed three
  factual errors this doc itself had accumulated: the quoted `Logger.warning` prefix
  (`"book scorer: ..."` in the doc, `"book manual search: ..."` in the code), the unique index's
  real name (`book_grabs_book_target_id_index`, not `book_grabs_book_target_id`), and "the
  'unmonitor' control the roadmap names" — the roadmap's own B5 Work list says "pause/resume", a
  term this doc had never actually seen in the roadmap text. The status line now pins the base SHA
  (`9f33e7d2`), matching B4a/B4b. Two other quoted code blocks (§6's `@type reason`, §7's
  `handle_info` clause) had also drifted from the real, evolving implementation during this round
  and are corrected in place — the same class of problem the `@spec` finding named, applied
  proactively rather than waiting for a ninth review to find them.
- **Not done, and why:** no test for the catch-all `handle_event/3`/`handle_info/2` fallback
  clauses (neither sibling detail view tests its own, and it would assert nothing beyond "no
  crash" on input no UI in this codebase sends); no test for `reload/1`'s `nil` branch (no code
  path deletes a `Work`); the discarded `{:exit, _reason}` in `handle_async` is left as-is (matches
  the sibling exactly). The `:unmonitored` blank-badge case is confirmed unreachable — both
  production callers of `Books.monitor_target/4` wrap it with `flip_pending`/the request-approval
  write in one `Repo.transaction` with `Repo.rollback` (`requests.ex:426-435`), so a failed
  `arm/2` rolls the `ensure_target/2` insert back — and stays recorded as a B5 obligation only, not
  fixed here.

### Third review round

- **The blocker regression test's rewrite and its own before/after proof are recorded above, in
  place, inside the BLOCKER bullet** — not repeated here — so a reader sees the mistake and the
  correction together rather than a clean second draft with the false start edited out of history.
  Also added in the same pass: malformed grab-index coverage (`"-1"`, `"abc"`, `"1.5"`, a missing
  `"index"` key) against a real `:loaded` socket built the same way (via the real `update/2`, with
  a preseeded `results:`), where `fetch_release/2`'s guard clauses — and, for the missing-key case,
  the plain `handle_event/3` catch-all — actually matter. Previously only `"0"` was ever tested.
- **`Cinder.Books.Grabs.track/2`'s doc corrected: the "completion edge" is not this function's to
  reach.** It read "advances only on real forward motion (or the completion edge)" — the edge
  (`content_path` going from unset to set) belongs to `mark_downloaded/2`; `track/2`'s own
  `is_nil(content_path)` guard means it never runs again once a grab is downloaded, so it could
  never observe that edge itself. Narrowed to describe only what `track/2` does.
- **`track/2`'s `download_progress_at` handling: still maintained, just moved.** The guarded
  `Repo.update_all` this round's fix added bypasses `BookGrab.changeset/2` entirely for this write
  path, so the schema's own private `advance_download_progress_at/2` no longer runs here — but the
  same "advance only on real forward motion" rule is not dropped, it is computed inline in
  `Cinder.Books.Grabs` itself (`progress_advanced?/2`, a second copy of logic the schema still
  applies for its *other* callers, `create/4` and `bump_attempts/2`, which still go through the
  changeset). This mirrors the split `Cinder.Catalog.Grab` (schema) and `Cinder.Catalog.Grabs`
  (context) already have between them — not a new pattern, and not a behavior this slice quietly
  removed.
