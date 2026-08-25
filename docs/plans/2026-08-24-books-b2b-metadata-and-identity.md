# Books B2b — metadata providers, identity resolution, and refresh

**Date:** 2026-08-24
**Roadmap item:** [`readarr-replacement-roadmap`](2026-08-20-readarr-replacement-roadmap.md), B2 (second of two slices)
**Contract:** [`books parity contract`](../specs/2026-08-20-books-parity-contract.md)
**Predecessor:** [`B2a`](2026-08-24-books-b2a-catalog-and-targets.md)
**Branch:** `feat/books-b2b-metadata-and-identity`

## Goal

Fill the B2a catalog from real providers. One `Cinder.Books.Metadata` behaviour, an Open Library
adapter (primary) and a Hardcover-proxy adapter (secondary), a conservative identity resolver that
returns an explained non-answer rather than a guess, and a refresher that survives a provider
outage. Still no LiveView, no acquisition, no book files.

## Design

### 1. `Cinder.Books.Metadata` — one behaviour, a list of impls

Two callbacks, mirroring the frozen proxy endpoints (`GET /search?q=`, `GET /work/{foreign_id}`):

```elixir
@callback search(query :: String.t()) :: {:ok, [candidate()]} | {:error, term()}
@callback get_work(foreign_id :: String.t()) :: {:ok, work()} | {:error, term()}
```

`candidate()` is provider-neutral and deliberately thin — the fields the matcher needs and nothing
more: `%{provider, foreign_id, title, contributors, first_published_year, edition_count}`.
`work()` adds `editions`, `series`, and per-subject identifiers.

Resolution order is config, not a priority column:

```elixir
config :cinder, Cinder.Books.Metadata,
  providers: [Cinder.Books.Metadata.OpenLibrary, Cinder.Books.Metadata.Hardcover]
```

Read with `fetch_env!` at runtime (Mox mocks are defined at runtime). `config/test.exs` points it
at `[Cinder.Books.PrimaryMetadataMock, Cinder.Books.SecondaryMetadataMock]`.

> Two mocks rather than one because the whole point of the pair is that they disagree; a single
> mock cannot express "primary unreliable, secondary accepts".

### 2. Adapters

Both are `Req` clients following `Catalog.TMDB.HTTP`: `Cinder.HTTPPolicy` origin pinning, a
`@max_response_bytes` cap, module config for `base_url`/timeouts, and normalization to the
provider-neutral shape. Neither adapter interprets evidence — reliability is the resolver's job.

- **`OpenLibrary`** — `GET /search.json`, `author_name` → `contributors`, `key` → `foreign_id`,
  `edition_key`/`isbn` carried for the edition layer. Public, no key.
- **`Hardcover`** — the Bookshelf `api.bookinfo.pro`-compatible proxy shape frozen in
  `provider-v1.json`. Base URL is deployment-specific, so it has no default: unconfigured, the
  adapter returns `{:error, :not_configured}` and the resolver degrades to Open Library alone.

**No Google Books adapter**, per the contract's provider decision (40/40 HTTP 429 keyless — no
acceptance criterion to build against).

### 3. `Cinder.Books.Identity` — conservative, explained

```elixir
resolve(query) ::
    {:ok, %{work: work(), provider: atom(), evidence: map()}}
  | {:unresolved, reason :: atom()}
  | {:error, :providers_unavailable}
```

A `"<provider>:work:<foreign_id>"` query takes the contract's durable-identity path and is an
exact fetch. Anything else is searched, and that is where the judgment lives — deliberately small:

1. Normalize to tokens (NFD fold, strip diacritics/punctuation, downcase). NFD runs *first*: the
   regexes raise on malformed UTF-8, and a garbled query must never raise out of a resolver the
   refresher calls in a loop.
2. A candidate is eligible only if one of its contributor names is present in the query, as a
   **token set** rather than a substring — "Cixin Liu" and "Liu Cixin" are the same person. No
   contributor evidence → never eligible. This alone kills every first-fuzzy-result failure.
3. Subtract the matched contributor tokens; the remainder is the target title. Compare it to the
   candidate title after stripping a leading article — exactly, or once the requester's format
   annotation (`omnibus`, `ebook`, `audiobook`) comes off. **One annotation, off the query only,
   never off the provider's title, and only from the trailing edge** — an annotation is something
   a requester appends, so only the tail can hold one. An exact match outranks a trimmed one.
4. A candidate is rejected when folding to ASCII would discard letters from either side, not just
   when it discards all of them. A non-Latin title keeps only its Latin residue, so
   "ノルウェイの森 1" and "海辺のカフカ 1" both key to "1" — and edition count handed back
   whichever was more popular, with full confidence. Diacritics still fold: combining marks are
   what the fold is *for*, so "Les Misérables" is fine and "Война и мир" is not.
5. Survivors order by match strength, then edition count, then foreign id, so the choice is
   deterministic. No survivor → `{:unresolved, :no_reliable_match}`.

Every clause of that sentence was paid for by a review round finding a query for one work
resolving to a *different* work:

| stripping | collision it produced |
|---|---|
| both sides | "The Book Thief" → "The Thief" |
| a long word list | "The Audio Book" → "The Book", "First Edition" → "First" |
| mid-string | "The Audiobook Murders" → "The Murders" |
| the leading edge | "Ebook Reader" → "Reader" |
| a run, not one word | "Omnibus Ebook Reader" → "Reader", right work rejected |
| keyed on the candidate | each candidate reshaped the query in its own favour |

Six rounds, each closing the reported instance while the class survived to the next. What finally
closed it is `Cinder.Books.IdentityCollisionTest`: ~1000 ordered pairs drawn from a bank of titles
built to exercise each fold — article, diacritic, punctuation, apostrophe, annotation, non-Latin
script — asserting that a query for one never resolves to another. It reproduces all six rounds
from the bank alone, and it found the leading-edge one itself. The frozen corpus structurally
cannot: `corpus-v1.json` holds no CJK, Cyrillic or Greek, and its only near-collisions are the
folds that are supposed to match.

**One collision is retained, and the fence asserts it rather than omitting it.** A title that
genuinely ends in an annotation word is indistinguishable from that title with a requester's
annotation appended — "The Complete Omnibus" against "The Complete" plus "omnibus" — and nothing
in a query separates the two readings. Dropping the trailing trim to avoid it would cost
`lord-of-the-rings` and put the corpus at 35/40, under the contract's bar. So it is kept, bounded
(strength precedence returns the named work whenever the provider also returned it, even against
99× the editions), and pinned to an exact expected set: narrowing the trim makes the residual
vanish and widening it makes the residual grow, and the test fails either way.

Walk providers in configured order; the first reliable result wins. All providers erroring is
`{:error, :providers_unavailable}` — distinct from "searched and found nothing", because the
refresher must treat them differently.

**Measured against the frozen fixtures.** As shipped the matcher agrees with
`metadata-provider-pair-v1.json`'s per-case `reliable` flag on **39/40**, resolves **36/40**
combined (90.0%, against the contract's ≥ 90% bar), and leaves all three contract-mandated cases
(`count-monte-cristo`, `leviathan-wakes`, `time-war`) unresolved. Two divergences are pinned in
`Cinder.Books.CorpusB2bTest` rather than tuned away:

- `the-talisman` — the matcher accepts, the fixture does not. The fixture's labelling used a
  `year_match` against an operator-supplied expected year; a resolver holding only a query has no
  such year. Hardcover accepts the case anyway, so the combined outcome is unchanged.
- `three-body-problem` — the fixture accepts, the matcher does not. Token-set matching reconciles
  "Cixin Liu" against the proxy's "Liu Cixin", but the query also names Ken Liu, the *translator*,
  whom the provider does not credit — so query-minus-contributors leaves a token the title cannot
  absorb. The fixture accepted on a known-contributor list (its own assessment records
  `contributor_match: false, known_contributor_match: true`) that a query-only resolver lacks.
  Widening the title rule to tolerate leftovers is precisely the fuzzy match the contract forbids.

**No `:ambiguous` outcome shipped**, contrary to this plan's first draft. Steps 2 and 3 make it
unreachable: every survivor already carries the same folded title *and* a matching contributor, so
a tie is two provider rows for one work (Open Library has several), never two different works.
Shipping a branch nothing can reach would have been dead surface.

Provider IDs are never equated across adapters. A work resolved by both gets two
`book_identifiers` rows, which is exactly what the contract's "never equated without recorded
identity evidence" requires.

### 4. Persistence

Reuses `Cinder.Books` upserts as-is — `upsert_author/1`, `upsert_work/1`, `upsert_edition/1`,
`put_identifier/2`, `put_credit/2`, `put_series_membership/2`. One new function,
`Cinder.Books.import_resolution/1`, folds a resolved `work()` into those calls in one
`mode: :immediate` transaction. Idempotence across provider aliases falls out of B2a's
identifier-keyed upsert. ISBN/ASIN needed one addition: they are now normalized on write, so
`978-1-4000-3341-6` and `9781400033416` are one identifier row rather than two nothing can join
on — which is what B2a's design meant by "normalized ISBN/ASIN live here" and nothing had
implemented. An ISBN already recorded against another edition is left pointing where it is;
re-pointing a normalized identifier is an identity change and the contract wants evidence for those.

Credits and series memberships are replaced wholesale on each import, so a work's contributor list
is exactly what the last successful import said rather than an accreted union of every provider
that ever ran.

`contributors_incomplete` is set here: true when the provider returns a work with zero credited
contributors, or when a credit references an author the payload never describes.

### 5. `Cinder.Books.Refresher`

`Cinder.Download.PollerSkeleton` (`stateful: false`), 12h, `:start_poller`-gated — the same shape
as `Catalog.Refresher`. Per work with a target, `isolate/2` a re-resolve by stored provider
identifier and re-upsert. Error paths **return** `{:error, _}`; nothing raises inside the isolated
unit (a raise re-fires every tick — `isolate` never parks).

Outage safety is one rule: **the refresher only writes fields the provider actually returned.** A
missing field never nils an existing value, and a failed fetch writes nothing at all. That covers
"retains the last valid snapshot" and "never strips acquisition identity" with no extra machinery.

### 6. Settings

New `:books` group ("Books metadata"), three registry fields:

| key | module/field | secret |
|---|---|---|
| `openlibrary_url` | `Metadata.OpenLibrary` / `:base_url` | no |
| `hardcover_url` | `Metadata.Hardcover` / `:base_url` | no |
| `hardcover_api_key` | `Metadata.Hardcover` / `:api_key` | yes |

Each also needs `SettingsLabels.known/0`, the FR gettext entries, and `settings_test`'s
`@env_keys` — the three gates a new settings field always trips.

## Deliberately not in this slice

- **Author aliases** (deferred here from B2a). The stated trigger was "B2b's adapters create the
  second spelling" — they do not. Each provider's spelling lands on its own identifier-keyed
  author row, which is the contract's required behaviour. Aliases only earn their keep once
  something searches *local* authors, which is B3. Revisit there.
- **Operator metadata overrides.** B2a shipped no override columns and nothing in B2b can set one,
  so the roadmap's "manual corrections survive refresh" has nothing to preserve and would be a
  vacuous test. The never-nil-an-existing-value rule (§5) is the half that is testable now; the
  criterion moves to B3 with the UI that creates a manual correction.
- **Provider health rows on `/status`.** Not a contract requirement. Add when an operator has a
  reason to look.
- **A provider-side ISBN fetch.** The contract's ISBN step is an edition-level signal for release
  matching and adoption (B5/B6). Nothing in B2b resolves from a bare ISBN, so a third `Metadata`
  callback for it now would be surface with no caller. `book_identifiers` already holds normalized
  ISBN/ASIN, so the local half is in place for whoever needs it first.
- **Edition-level contributors.** The Hardcover payload carries them, narrator included, which
  matters for audiobooks — but B2b acquires nothing, so there is no consumer. B7 owns audiobooks.
- LiveView, book files, acquisition, author monitoring policies.

## Done when

All verified. `mix test` green at 3237.

1. `search/1` and `get_work/1` normalize the frozen payload shapes; an oversized body, a non-200,
   a malformed body, and a transport error each return `{:error, _}` and never a partial work.
2. An unconfigured Hardcover base URL returns `{:error, :not_configured}` and the resolver still
   answers from Open Library alone.
3. Across the 40-case corpus the configured pair resolves 36/40 (90.0%, contract bar ≥ 90%) with
   **zero** silent first-result selections.
4. `count-monte-cristo`, `leviathan-wakes`, and `time-war` return an explained unresolved state.
5. A candidate with no contributor evidence in the query is never selected, however well its title
   scores — mutation-proven: removing the guard fails 6 tests.
6. Importing the same book from each provider is two identities, never a merge; an ISBN variant of
   the same import is one edition and one normalized identifier row. The no-re-point rule is
   mutation-proven.
7. A contributor the provider named but did not identify is dropped, not invented, and the work
   lands `contributors_incomplete: true`.
8. A refresh whose provider errors leaves every work, edition and identifier byte-identical, and
   returns `{:error, _}` rather than raising — `isolate/2` only logs what it rescues, so a raise
   would recur every tick with nothing parked.
9. A refresh returning a payload missing a previously-populated field does not clear it —
   mutation-proven: removing `drop_nils/1` fails 2 tests.
10. One work failing does not stop the pass, and leaves no rescued exception in the log.
11. No behaviour changes outside `lib/cinder/books*`, the settings registry/labels/setup copy and
    gettext catalogs, `config/*.exs`, `application.ex`, and the tests.
