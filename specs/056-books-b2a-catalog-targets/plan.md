# Books B2a — catalog schemas, identifiers, credits, and book targets

**Date:** 2026-08-24
**Roadmap item:** [`readarr-replacement-roadmap`](2026-08-20-readarr-replacement-roadmap.md), B2 (first of two slices)
**Contract:** [`books parity contract`](../specs/2026-08-20-books-parity-contract.md)
**Branch:** `feat/books-b2a-catalog-and-targets`
**Council review:** n/a

## Goal

Land the durable books catalog — author, work, edition, identifier, credit, series membership —
and the `(work, media_kind)` monitoring target with its guarded transition. **No network, no
metadata provider, no LiveView.** Everything in this slice is exercisable with plain Ecto and the
committed B0 fixtures.

B2b then adds `Cinder.Books.Metadata`, the Open Library and Hardcover adapters, identity
resolution against the 40-case corpus, and the refresher. Splitting here is deliberate: B2 is
8–12 developer-days, and the schema half is fully testable without a single HTTP stub, so it can
be reviewed on its own.

## Slice boundary (agreed 2026-08-24)

- **Two PRs**, B2a then B2b, instead of one B2 PR.
- **No Google Books adapter, in either slice.** The parity contract supersedes the roadmap's
  "optional Google Books fallback": keyless evaluation returned 40/40 HTTP 429, so it has no
  acceptance criterion to build against
  ([contract, Metadata provider decision](../specs/2026-08-20-books-parity-contract.md)).
  Open Library primary plus a Hardcover-compatible secondary is the required pair.

## Design

Seven new tables, one migration, `change/0` only — this is purely additive, so none of the
rebuild machinery from `20260824064512_add_book_profile_kinds.exs` applies.

### 1. Identity layers

`book_authors`, `book_works`, `book_editions` are the three catalog layers the contract locks
(the fourth, *file*, arrives in B4).

| Table | Columns |
|---|---|
| `book_authors` | `name`, `sort_name` (nullable), `disambiguation` (nullable) |
| `book_works` | `title`, `original_title` (nullable), `first_published_on` (nullable `:date`), `overview` (nullable), `contributors_incomplete` (boolean, default `false`) |
| `book_editions` | `work_id` (FK, `on_delete: :delete_all`), `media_kind` (`:ebook`/`:audiobook`), `title`, `language` (nullable), `format` (nullable string), `publisher` (nullable), `release_date` (nullable `:date`), `abridged` (nullable boolean) |

`contributors_incomplete` exists because the contract locks the "incomplete" signal as a data-model
requirement, not a provider detail: twelve corpus cases omit an expected public contributor even
when work identity is acceptable, and the adapter "must not invent missing identities". B2b sets
it; B2a proves it defaults to `false` and is castable.

Display names are **not** join keys. Identity is `book_identifiers`.

### 2. `book_identifiers` — namespaced provider identity

Contract: provider IDs are namespaced tuples `(provider, kind, foreign_id)`, never untyped
integers. One table, three nullable subject FKs, exactly one set:

```
add :author_id,  references(:book_authors,  on_delete: :delete_all)
add :work_id,    references(:book_works,    on_delete: :delete_all)
add :edition_id, references(:book_editions, on_delete: :delete_all)
add :provider,   :string, null: false      # "openlibrary" | "hardcover" | "isbn" | "asin"
add :kind,       :string, null: false      # "work" | "edition" | "author" | "isbn13" | "asin"
add :foreign_id, :string, null: false
```

- check `book_identifiers_one_subject`:
  `(author_id IS NOT NULL) + (work_id IS NOT NULL) + (edition_id IS NOT NULL) = 1`
- `create unique_index(:book_identifiers, [:provider, :kind, :foreign_id])` — unnamed, so the
  changeset's `unique_constraint([:provider, :kind, :foreign_id])` uses Ecto's column-derived
  name and the collision returns a changeset error instead of raising `Exqlite.Error`.

Real FKs rather than a polymorphic `subject_type`/`subject_id` pair, because the contract requires
the four surfaces to stay "referentially valid" and SQLite cannot enforce a polymorphic reference.

Normalized ISBN/ASIN live here too, under the `"isbn"`/`"asin"` provider. That keeps one lookup
path for "what identifies this edition" instead of a second near-identical table.

### 3. `book_credits` — role-bearing, ordered

Contract: work↔contributor and edition↔contributor are both many-to-many, role-bearing, ordered.

```
add :author_id,  references(:book_authors,  on_delete: :delete_all), null: false
add :work_id,    references(:book_works,    on_delete: :delete_all)
add :edition_id, references(:book_editions, on_delete: :delete_all)
add :role,     :string,  null: false   # "author" | "editor" | "translator" | "narrator" | provider role
add :position, :integer, null: false, default: 0
```

- check `book_credits_one_subject`: exactly one of `work_id` / `edition_id` is set.
- `unique_index(:book_credits, [:work_id, :author_id, :role])` and
  `unique_index(:book_credits, [:edition_id, :author_id, :role])`. SQLite treats NULLs as
  distinct in unique indexes, so each index only constrains rows of its own subject — which is
  exactly what we want.

`role` stays a string, not an `Ecto.Enum`: it is provider vocabulary, following the
`Catalog.Episode` classification-source precedent.

### 4. `book_series_memberships` — flat, no series identity

```
add :work_id,  references(:book_works, on_delete: :delete_all), null: false
add :name,     :string, null: false
add :position, :string          # nullable; "1", "1.5", "Book Two" — never coerced
add :provider, :string, null: false
```

**No `book_series` table.** Series is explicitly *not* one of the contract's identity boundaries
("series membership is separate from work identity"), and nothing in B2–B6 resolves a series by
provider ID. A flat membership row per (work, series name) keeps the position lossless and lets
B3 group by name. Marked with a `ponytail:` comment naming the ceiling and the upgrade path
(promote to a `book_series` table with its own identifiers the day series get their own page or
provider-ID dedup).

`position` is a nullable string so the `eye-of-the-world` case — provider omits the position, the
operator expects `1` — is representable as "absent", and so a position is never parsed out of
title text.

### 5. `book_targets` — the monitoring unit

Monitoring is explicit at `(work, media_kind)` and independent per kind.

```
add :work_id,     references(:book_works, on_delete: :delete_all), null: false
add :media_kind,  :string, null: false        # ebook | audiobook
add :status,      :string, null: false, default: "unmonitored"
add :profile_id,  references(:media_profiles, on_delete: :restrict)
add :hold_reason, :string                     # set iff status = held
```

- `unique_index(:book_targets, [:work_id, :media_kind])` — a work can monitor ebook, audiobook,
  both, or neither, but never twice.
- check `book_targets_status_valid`: `status IN ('unmonitored','monitored','available','held')`.
- check `book_targets_media_kind_valid`: `media_kind IN ('ebook','audiobook')`.
- triggers `book_targets_profile_integrity_insert` / `_update`, mirroring the six existing
  profile-integrity triggers verbatim in shape: a book target may only reference a
  `media_profiles` row whose `kind` equals the target's `media_kind`. Registered on the changeset
  via `check_constraint(:profile_id, name: "book_targets_profile_integrity")`, so a mismatch is a
  field error rather than an `Exqlite.Error`.

`on_delete: :restrict` on `profile_id` matches `media_profiles`' existing referential policy.

**No legal-transition map.** All twelve ordered state pairs are genuinely reachable —
adoption (B6) can move `unmonitored → available` without ever passing through `monitored`, and a
hold resolves back to any of the other three. A legality table here would be ceremony that the
first real caller has to amend. The `expect:` CAS is the actual guard; the changeset validates
status inclusion.

### 6. `Cinder.Books.BookTargetTransition` — the choke-point

Copies `Catalog.transition/3`'s `expect:` form exactly (see `catalog.ex:486` and
`catalog/episode_transition.ex`):

1. Build and validate the changeset before writing.
2. `Repo.update_all(from(t in BookTarget, where: t.id == ^id and t.status == ^expected, select: t), set: ...)` — `select:` is what gives SQLite `RETURNING` and the fresh row.
3. Set `updated_at` manually; `update_all` does not apply schema timestamps.
4. `{0, _}` → `{:error, :stale_status}`, rolled back inside `Repo.transaction`.
5. Broadcast **once, after commit**, on a new `"book_targets"` topic
   (`Cinder.Books.subscribe_targets/0`, `broadcast/1`), following `Catalog`'s flat-row-broadcasts-
   the-struct convention. A stale write broadcasts nothing.

### 7. `Cinder.Books` — the context

Only what this slice's tests call. Target status is written **only** through the transition;
everything else is a sanctioned direct write, same doctrine as `Cinder.Catalog`:

- `upsert_author/1`, `upsert_work/1`, `upsert_edition/1` keyed on a namespaced identifier
- `put_identifier/2`, `put_credit/2`, `put_series_membership/2`
- `get_work/1` (with a documented preload set), `list_targets/1`
- `ensure_target/2` (create `unmonitored` if absent — idempotent)
- `transition_target/3` with `expect:`

### 8. Fail-closed checks that stay closed

- `requests_profile_integrity` still accepts only `movie→movies` and `series|season|episode→tv`;
  a request may not reference a book profile. Regression test asserts the abort (B1 added this;
  B2a must not weaken it).
- `Profiles.assign_profile/3` still has no book clause. A book target's profile is set through
  `Cinder.Books`, not `Catalog.Profiles`.

## Done when

`mix test` is green and each of these has a test:

1. Work and edition are separate rows; an edition belongs to exactly one work.
2. A `book_identifiers` row with zero or two subjects is rejected by the check constraint.
3. A duplicate `(provider, kind, foreign_id)` returns `{:error, changeset}`, not a raise.
4. Credits preserve `role` and `position`, on both works and editions; the same author can hold
   two roles on one work.
5. A series position round-trips as `"1"`, `"1.5"`, and `"Book Two"` without coercion, and a
   work can hold memberships in two series.
6. `contributors_incomplete` defaults to `false` and is castable to `true`.
7. `(work_id, media_kind)` is unique; ebook, audiobook, both, and neither are all representable.
8. A target referencing a `movies` profile fails as a changeset error on `:profile_id`.
9. A legal transition persists, returns the fresh `RETURNING` row, and broadcasts exactly once
   after commit.
10. A stale `expect:` returns `{:error, :stale_status}`, writes nothing, and broadcasts nothing.
11. `ensure_target/2` is idempotent.
12. Deleting a work cascades its editions, identifiers, credits, and memberships; deleting a
    `media_profiles` row that a target references is restricted.
13. A request still cannot reference a book profile.
14. Existing movie/TV behaviour is untouched — no file outside `lib/cinder/books/`,
    `lib/cinder/books.ex`, and the migration changes behaviour.

## Explicitly not in this slice

Metadata behaviour and adapters, identity resolution, the refresher and its supervision entry,
settings registry keys for providers, any LiveView, book files, and acquisition. All B2b or later.

## Review findings applied (2026-08-24)

One bounded adversarial review of the complete diff produced seven findings. Five were fixed in
this slice, one was deferred, one was rejected.

Fixed:

1. `upsert_edition/1` loaded an existing edition by identifier and overwrote its metadata while
   ignoring the caller's `work_id`, silently leaving the edition under the wrong work. Now rolls
   back with `:identifier_subject_mismatch`.
2. The existing reverse trigger `media_profiles_references_integrity_update` did not know about
   `book_targets`, and `Profile.changeset/2` casts `:kind` on update — so editing an ebook profile
   to `kind: :audiobook` in `/settings` stranded an ebook target on an audiobook profile. The
   trigger is dropped and recreated here with a fourth `EXISTS` arm; `down` restores the previous
   body verbatim.
3. `upsert_by_identifier/5` is a read-then-write, so its transaction now uses `mode: :immediate`,
   matching `Catalog.Profiles` and `Cinder.Requests`. No test: the Ecto sandbox is
   single-connection, so a concurrency test here would be vacuous.
4. `transition_changeset/2` no longer casts `:profile_id`. `Repo.update_all` bypasses
   `to_constraints`, so a wrong-kind profile fired the integrity trigger as a raw `Exqlite.Error`
   instead of `{:error, changeset}`. Profile assignment is a separate concern from a status
   transition here, exactly as `Profiles.assign_profile/3` is separate from `Catalog.transition/3`.
   No `Books.assign_target_profile/2` was added — nothing in B2a calls one.
5. Leaving `:held` no longer requires the caller to clear `hold_reason` explicitly; it is cleared
   automatically when the status changes away from `:held`. Both invariants still hold.

Deferred to B2b — **author aliases**. The contract makes display names and aliases mutable
metadata on a namespaced contributor identity, so a second provider-backed spelling of one author
currently overwrites `book_authors.name`. Nothing in B2a searches or refreshes authors, so an
alias table here would have no consumer and no acceptance criterion. B2b's provider adapters are
what create the second spelling; the alias representation lands with them.

Rejected — no-op transitions still touch `updated_at` and broadcast. `Catalog.transition/3` and
`EpisodeTransition` behave identically, and no caller demonstrates harm.
