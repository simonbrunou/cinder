# Books B3b — discovery, work page, and the request UI

**Date:** 2026-08-25
**Roadmap item:** [`readarr-replacement-roadmap`](2026-08-20-readarr-replacement-roadmap.md), B3 (second of two slices)
**Contract:** [`books parity contract`](../specs/2026-08-20-books-parity-contract.md)
**Predecessor:** [`B3a`](2026-08-25-books-b3a-requests-and-approval.md)
**Branch:** `feat/books-b3b-discovery-and-request-ui`

## Goal

Give a household member a way to *reach* the request path B3a built: search books from Discover,
open a work, and press "Request eBook" / "Request audiobook". Nothing below writes a new table —
this slice is a search function, a route, a LiveView, and one component module.

## Scope

B3's roadmap entry parks two orphans in this slice. Both stay parked, for the same reason B1
parked `book_target.ex`: no caller.

- **Author aliases and local author search** belong to the author-monitoring surface. B5 owns it.
- **Operator metadata overrides** need something that edits metadata. Nothing here does; the work
  page is read-only. Moves to whichever milestone first offers an edit control.
- **Books in `/library`** waits for B4. Until an import writes a `book_files` row there is nothing
  to list but empty rows.

## Design

### 1. `Cinder.Books.search/1` is not `Identity.resolve/1`

`Identity.resolve/1` returns *one* work and refuses on ambiguity — correct for authorizing a grab,
wrong for a search grid, where showing the operator the ambiguity is the whole point.

```elixir
@spec search(String.t()) :: {:ok, [Metadata.candidate()]} | {:error, :providers_unavailable}
def search(query)
```

Walks `Metadata.providers()` in order and returns the first provider that answers with a
**non-empty** list. `{:ok, []}` falls through to the next provider — an empty grid next to a
working secondary is worse than a slower query, and no-hit queries are the rare case. If every
provider errors, `{:error, :providers_unavailable}`; if they all answer empty, `{:ok, []}`.

No cross-provider merge. The pair exists *because* the two disagree (B2b); interleaving two
relevance orders invents a third ranking nobody validated.

### 2. Candidates carry no local state, so overlay it

A candidate is a provider payload. The card badge needs Cinder's own view, so:

```elixir
@spec work_ids_by_reference([{atom() | String.t(), String.t()}]) :: %{{String.t(), String.t()} => integer()}
```

One `book_identifiers` query (`kind: "work"`) mapping `{provider, foreign_id} → book_works.id`.
The LiveView joins that against `Requests.list_for_user/1` (book rows, keyed by
`{target_id, media_kind}`) to badge each card. Candidates with no local work render a plain link.

### 3. Route: `/book/:provider/:foreign_id`, and it is a *discovery* page

Mirrors `/movie/tmdb/:tmdb_id`, not `/movies/:id`. The roadmap's `book_detail_live.ex` names the
admin pipeline view of a work Cinder already tracks; that view has nothing to show until B4 gives
it files and a running target, so this slice creates `BookDiscoveryLive` instead and leaves
`/books/:id` unclaimed.

Mount:

1. Validate `:provider` against `Metadata.providers()`. Unknown → 404. This is why the LiveView
   parses the provider itself rather than handing the raw string to `Identity.resolve/1`, which
   would treat `"nonsense:work:x"` as free text and spend two provider searches on it.
2. `start_async` → `Identity.resolve(Identity.reference_for(provider, foreign_id))`. The contract
   locks book metadata at "asynchronous, visibly loading, tolerant of five-second searches"; a
   synchronous mount would hold the connection for the p95.
3. `{:error, :providers_unavailable}` renders an inline retry state, never a 404 — same rule
   `MovieDiscoveryLive` applies to a TMDB outage. Cinder cannot currently distinguish "unknown
   foreign id" from "provider down" here (`Identity.fetch/2` collapses both), so the copy stays
   honest about that rather than asserting the book does not exist. Splitting the two means
   changing `Identity`; not worth it for a hand-typed URL.

Renders: title, contributors with roles, first published year, overview, series memberships,
and a digital-editions summary (count per media kind, languages). No edition picker — `book_targets`
carries no edition policy, so there is nothing for a pick to land in.

### 4. Requesting

One button per book media kind that has at least one configured profile. `Requests` refuses a book
approval without one (B3a `approved_book_profile/1`), so offering the button without a profile
would only manufacture a failure. With none configured, an admin sees a link to
`/settings/profiles`; a non-admin sees a plain "not available yet" line.

No profile picker and no language/format control on this surface — the roadmap is explicit that
indexer, format and ISBN jargon stays off requester surfaces. The request carries
`RequestHelpers.default_profile_id/2`'s standard profile for the kind; an admin can change it in
`/requests` before approving.

The press is one `start_async`:

```elixir
{:ok, work} = Books.import_resolution(resolution)
Requests.create_request(user, %{
  target_type: "book", target_id: work.id, media_kind: kind,
  proposed_profile_id: id, proposed_media_profile: :standard
})
```

`import_resolution/1` before `create_request/2` because `target_id` is a local `book_works.id` and
B3a's `snapshot_request/1` fails closed on a missing work. It is idempotent, so a second press or
a second requester re-imports in place.

Result handling reuses `RequestHelpers.request_result/3` verbatim — quota, duplicate-pending, and
approved-vs-pending flashes are already right for books.

Live badges: subscribe to `Cinder.Requests` and `Books.subscribe_targets/0`. A `:monitored` target
means an admin approved; an `:available` one means B4 delivered it.

### 5. Discover

`DiscoverLive` gains `book_results` / `books_state` assigns and a `:book` filter chip. The existing
`handle_event("search", ...)` keeps its synchronous TMDB call and additionally fires
`start_async({:books, query}, ...)` for queries of three characters or more. `handle_async` drops a
result whose tagged query is not the current one, so a 5s provider answer cannot overwrite the grid
for a query the user has since retyped.

Book cards render in their own section, not through `media_grid/1`: a candidate has no poster path
and no tmdb_id, and reshaping it into the movie/TV card contract to share one grid would cost more
than a second section. The filter-chip row's `:if` widens to cover a books-only result set.

A books provider outage renders an inline note in the books section only. It must not disturb the
movie/TV results on the same page.

### 6. Deliberate omissions

- **No cover art.** `Metadata.candidate()` carries none; adding it means the behaviour, both
  adapters, and every frozen fixture. Add when the text grid proves too sparse to scan.
- **No search cache.** `phx-debounce="300"` plus the three-character floor is the cheap 90%. Add a
  cache when a repeated query is measurably the common case.
- Both get a `ponytail:` comment at the site.

## Files

- Modify: `lib/cinder/books.ex` — `search/1`, `work_ids_by_reference/1`
- Create: `lib/cinder_web/live/book_discovery_live.ex`
- Create: `lib/cinder_web/components/book_components.ex` — `book_cards/1`, `book_state_badge/1`
- Modify: `lib/cinder_web/live/discover_live.ex`
- Modify: `lib/cinder_web/router.ex`
- Modify: `priv/gettext/**` (extract/merge **last**)
- Test: `test/cinder/books_search_test.exs`
- Test: `test/cinder_web/live/book_discovery_live_test.exs`
- Test: `test/cinder_web/live/discover_books_test.exs`

## TDD sequence

### RED — `Books.search/1`

1. Primary answers with candidates → exactly those, in provider order; secondary never called.
2. Primary `{:error, _}`, secondary `{:ok, [_]}` → the secondary's candidates.
3. Primary `{:ok, []}`, secondary `{:ok, [_]}` → the secondary's candidates.
4. Both `{:ok, []}` → `{:ok, []}`.
5. Both error → `{:error, :providers_unavailable}`.
6. `work_ids_by_reference/1` maps only `kind: "work"` identifiers and omits unknown references.

### RED — `BookDiscoveryLive`

7. Unknown `:provider` segment → 404.
8. Resolve failure renders the retry state and a 200, not a 404.
9. Non-admin request inserts one `:pending` request and **no** `book_target`.
10. Admin request auto-approves and leaves exactly one `:monitored` target carrying the default
    eBook profile.
11. eBook and audiobook are independently requestable for one work; requesting one leaves the
    other's button live.
12. A second press on an already-pending kind flashes "already requested" and inserts nothing.
13. No configured profile for a kind → that kind's button is absent; an admin sees the settings
    link.
14. An approval broadcast on the targets topic updates the badge without a reload.

### RED — `DiscoverLive`

15. A books result set renders book cards and the Books filter chip.
16. `:book` filter hides movie/TV results and vice versa.
17. Provider outage renders the books note while the movie results stay on the page.
18. A stale `{:books, old_query}` async result is discarded.
19. A two-character query fires no books search.

### GREEN, then REFACTOR

Implement in the order above. `mix gettext.extract --merge` runs **once, last**, after every `lib/`
edit — `#:` line refs drift and CI's `--check-up-to-date` fails on a mid-work extract.

## Done when

1. A household member can find a book from `/`, open it, and request it as an eBook or an
   audiobook, with no managed target created before an admin approves.
2. An admin's own request auto-approves under `auto_approve_all` and lands one `:monitored` target.
3. A books-provider outage degrades the books section only — Discover, movies, and TV are untouched.
4. No requester surface exposes an indexer, format, ISBN, or profile-handling control.
5. All new copy is gettext'd, in both locales, and `--check-up-to-date` passes.
6. `mix test` is green.
