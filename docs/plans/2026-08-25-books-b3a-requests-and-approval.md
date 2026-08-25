# Books B3a — book requests, approval, and target creation

**Date:** 2026-08-25
**Roadmap item:** [`readarr-replacement-roadmap`](2026-08-20-readarr-replacement-roadmap.md), B3 (first of two slices)
**Contract:** [`books parity contract`](../specs/2026-08-20-books-parity-contract.md)
**Predecessor:** [`B2b`](2026-08-24-books-b2b-metadata-and-identity.md)
**Branch:** `feat/books-b3a-requests-and-approval`
Council review: skipped — this session's directive disallows subagent fan-out.

## Goal

Make a book requestable through the existing approval gate. `Cinder.Requests` learns a `"book"`
target whose `target_id` is a local `book_works.id` and whose `media_kind` is `:ebook` or
`:audiobook`; approval creates and monitors the matching `book_target`. Data model, context, and
`/api/v1` only — Discover and the work-detail page are B3b.

## Why sliced

B3 as written is 7–10 developer-days spanning the request data model, the approval path, the API,
Discover, a new work-detail LiveView, and the shared request components. The half below is
provable by `mix test` without a single `.heex` file, and B3b needs it to exist first: a Discover
card can only offer "Request eBook" once something can accept that request. Same split rationale
as B2a/B2b.

## Design

### 1. `requests` grows a media-kind axis, not a second table

A book request is the same polymorphic row every other request is: `target_type: "book"`,
`target_id: <book_works.id>`, plus a new `media_kind` column. The roadmap's "do not overload the
current integer TMDB field with provider-specific strings" is honoured because `target_id` stays
an integer — Cinder's own work id, not an Open Library key. The provider identity already lives
in `book_identifiers`; a request does not need to repeat it.

`media_kind` is the contract's `(work, media_kind)` monitoring axis. Without it a household member
could not have both an eBook and an audiobook request open for one work: `requests_pending_unique`
is `(user_id, target_type, target_id, COALESCE(season_number, -1))` and the two rows would
collide. The index therefore gains `COALESCE(media_kind, '')`.

Presence is symmetric and changeset-enforced: `"book"` requires a `media_kind`, every other
target type forbids one. No DB `CHECK` — `target_type`'s own allowlist is changeset-only too, and
adding a table constraint to `requests` would mean a full SQLite table rebuild for a rule no other
writer can violate.

### 2. The profile-integrity triggers get a book arm

`requests_profile_integrity_insert/update` currently abort unless the proposed profile's kind
matches a `movie`/`series` arm. A book request carrying a profile hits `NOT EXISTS` on every arm
and raises, so the trigger must learn:

```sql
(NEW.target_type = 'book' AND kind = NEW.media_kind)
```

`AND handling = NEW.proposed_media_profile` stays common to all arms — book profiles are
`:standard` only (`LibraryKind.handlings/1`), so the clause holds without a special case. The
update trigger's `UPDATE OF` list gains `media_kind`, and
`media_profiles_references_integrity_update`'s `requests` arm gains the same disjunct so an
operator cannot re-kind a profile out from under a book request.

`Profiles.referenced?/1` already counts requests and book targets — no change ([[media-profiles
reference has two halves]] is satisfied by the trigger edit alone).

### 3. Approval is one guarded write

`Books.monitor_target/4` is the approval choke-point:

```elixir
def monitor_target(%Work{} = work, media_kind, %Profile{} = profile, opts \\ [])
```

It ensures the `(work, media_kind)` target exists, then makes **one** guarded transition carrying
both the profile and the next status. `:unmonitored` becomes `:monitored`; `:monitored` and
`:available` keep their status and only take the profile, because a second requester must not
downgrade an already-satisfied target.

`:held` is refused outright with `{:error, :target_held}`. Not re-arming it is not enough:
approving *onto* a held target would flip the request to `:approved` and mail the requester that
Cinder is looking for a copy while the hold means nothing ever searches. The contract makes
`:held` an operator-visible conflict that only an operator clears, so the approval has to fail
and say why.

`BookTarget.transition_changeset/2` therefore casts `:profile_id` as well. `publish: false` mirrors
`Catalog.assign_profile/3`: the approval runs inside a transaction and the
`{:book_target_updated, target}` broadcast is emitted by `Cinder.Requests` after commit.

### 4. A book request needs a book profile

`create_approved/3` and `approve_request/3` both resolve a `%Profile{kind: media_kind}` before
touching the target, defaulting to the lowest-id `:standard` profile of that kind. With no eBook
profile configured, approval fails closed with `:invalid_media_profile` rather than creating a
target the B4 acquisition path could not score. Requesters are unaffected — a `:pending` row
carries no profile.

`request_kind/1` moves from a `target_type` string to the request/attrs map, because `"book"`
alone does not name a kind.

### 5. Snapshot from the local catalog, not a provider

`snapshot_request/1` becomes `{:ok, attrs} | {:error, reason}`. The book clause reads
`book_works` for the title and `first_published_on`'s year; a missing work is
`{:error, :unknown_work}` instead of a title-less request row. The movie/TV clauses keep their
existing tolerance of a provider miss.

### 6. `/api/v1`

`for_api/1` and `export_for_user/1` project `media_kind`. `POST /api/v1/requests` accepts
`target_type: "book"` with a `media_kind`, and `named_profile/2`'s hardcoded
`if target_type == "movie", do: :movies, else: :tv` learns books — extending the create allowlist
without it would silently validate a book request against TV profiles.

`CinderWeb.RequestHelpers.profile_kind/1` has the same `else: :tv` default and feeds the admin
approval queue's profile picker; it gets the same book clause.

## Deliberately not in this slice

- **Discover, the work-detail route, and book request components.** B3b.
- **Author aliases and local author search.** B2b deferred them "to B3"; they belong to the
  search surface, which is B3b.
- **Operator metadata overrides** ("manual corrections survive refresh"). Still no UI that creates
  one; still vacuous. Moves to B3b with the detail page.
- **Cover art.** `requests.poster_path` stays nil for books. Nothing renders it until B3b.
- **`reap_approved_for_target/2` for books.** No book deletion path exists before B5/B8.
- **`approved_requesters_for_*`.** They exist to fan availability/failure notifications out; books
  cannot become available until B4.
- **Edition-specific requests** (`edition_policy`). The contract's request boundary is the work;
  B5/B6 own edition selection.

## TDD sequence

### RED

1. `Request.create_changeset/2` rejects `"book"` without `media_kind`, and rejects `media_kind`
   on a movie/season request.
2. Two pending requests for one work differing only in `media_kind` both insert; a duplicate of
   either returns `{:error, changeset}`.
3. `Requests.create_request/2` for an unknown work id returns `{:error, :unknown_work}`.
4. A non-admin book request creates a `:pending` row and **no** `book_target`.
5. Admin approval creates a `:monitored` target carrying the approved profile, and is idempotent
   across a re-request.
6. Approving with a `:tv` profile, or with no eBook profile configured, returns
   `{:error, :invalid_media_profile}` and creates no target.
7. Approving a work whose target is `:held` fails with `{:error, :target_held}` and creates no
   request; approving one that is `:available` leaves it `:available` and takes the profile.
8. A book request carrying a book profile survives the integrity trigger; one carrying a
   mismatched-kind profile is rejected by it. Re-kinding a referenced profile aborts.
9. `for_api/1`, `export_for_user/1`, and `POST /api/v1/requests` round-trip `media_kind`.

### GREEN

Migration, schema, `Books.monitor_target/4`, `Requests` book clauses, API + helper kind mapping.

### REFACTOR / verification

`mix test` green; `git diff` shows no behaviour change on the movie/TV paths.

## Done when

1. A household member can request a work as an eBook, and no `book_target` exists until an admin
   approves.
2. An admin's own book request auto-approves under the existing `auto_approve_all` rules and
   lands one `:monitored` target.
3. One work can hold an independent eBook and audiobook request and target.
4. Approval never downgrades `:available`, and refuses outright on `:held` rather than approving
   a request nothing will act on.
5. A book request cannot reference a movie/TV profile, at the changeset **and** the trigger level.
6. `mix test` is green.
