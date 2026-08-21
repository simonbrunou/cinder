# Books B0 — inventory and parity contract

**Status:** Accepted for B0 on 2026-08-20
Council review: n/a
**Roadmap:** [`docs/plans/2026-08-20-readarr-replacement-roadmap.md`](../plans/2026-08-20-readarr-replacement-roadmap.md), milestone B0
**Evidence:**
[`bookshelf-inventory-v1.json`](../audits/data/bookshelf-inventory-v1.json),
[`bookshelf inventory audit`](../audits/2026-08-20-bookshelf-inventory.md),
[`books parity matrix`](../audits/data/books-parity-matrix-v1.json),
[`metadata provider decision`](../audits/data/books-provider-decision-v1.json),
[`corpus-v1.json`](../../test/support/fixtures/books/corpus-v1.json),
[`metadata-provider-pair-v1.json`](../../test/support/fixtures/books/metadata-provider-pair-v1.json),
[`provider-v1.json`](../../test/support/fixtures/books/provider-v1.json), and
[`bookshelf-api-v1.json`](../../test/support/fixtures/books/bookshelf-api-v1.json)

This contract defines the compatibility target for replacing the household's two
Bookshelf/Readarr-fork instances. It intentionally adds no production book code. B1 and later
milestones may refine implementation details, but changing a locked decision below requires an
explicit spec change and corresponding fixture update.

## Evidence and method

The active deployment was read through Bookshelf's authenticated, read-only `/api/v1` endpoints.
The capture covered system status, authors, works, per-work editions, files, quality profiles,
library roots, naming/media-management settings, download-client protocol classes, indexer
protocol classes, and monitoring flags. The two consumers' mounted library roots were inspected
separately to verify the handoff boundary.

The deployment runs `pennydreadful/bookshelf:hardcover`, application version `0.4.20.129` on the
`develop` branch, image source revision
[`c21c4134`](https://github.com/pennydreadful/bookshelf/commit/c21c4134fdb710481ed69db05bf943b0acdbbf60),
and the `https://api.bookinfo.pro` Hardcover metadata proxy. The exact image digest is frozen in
the aggregate inventory.

Raw responses remain outside source control because titles, authors, provider IDs, hostnames, and
paths reveal household data. The committed inventory contains only aggregate counts and policy
values. The committed Bookshelf API fixture was structurally derived from the live responses, then
all identities, bibliographic identifiers, paths, timestamps, file sizes, ratings/popularity/votes,
release dates, page counts, aggregate statistics, descriptions/images, and audio measurements were
replaced with deterministic synthetic values. Only response keys/types, boolean and enum semantics,
quality/profile names, and relevant policy configuration remain live-derived. Credentials were
never written to an artifact.

## Inventory snapshot

| Surface | eBooks instance | Audiobooks instance |
|---|---:|---:|
| Authors | 2 (2 monitored) | 2 (1 monitored) |
| Works | 842 (842 monitored) | 170 (1 monitored) |
| Editions | 2,391 (841 monitored) | 651 (169 monitored) |
| Files | 188 | 1 |
| Final formats | 159 EPUB, 25 AZW3, 4 MOBI | 1 M4B |
| Quality profile | `eBook` | `Spoken` |
| Download clients | 1 torrent, 1 Usenet | 1 torrent, 1 Usenet |
| Indexers | 3 torrent, 3 Usenet | 3 torrent, 3 Usenet |
| Consumer | Booklore | Audiobookshelf |

Both instances enable completed-download handling, prefer hardlinks, reserve 100 MB before import,
and have automatic renaming disabled. Their configured standard-name template is
`{Book Title}/{Author Name} - {Book Title}{ (PartNumber)}` but is dormant while renaming is off.

### Representative metadata/search latency

Ten sequential public-title searches through the active eBook Bookshelf API, measured from inside
its LXC with the deployment's existing mixed cache state, all succeeded: 272.3 ms minimum,
2,701.6 ms p50, 4,686.8 ms p95, and 5,167.7 ms maximum. Ten sequential accepted-corpus work
lookups against the configured metadata proxy from the capture host also all succeeded: 60.6 ms
minimum, 63.4 ms p50, 78.6 ms p95, and 84.8 ms maximum.

This is a representative deployment snapshot, not a load benchmark. B2 discovery must therefore be
asynchronous, visibly loading, cached, and tolerant of at least five-second end-to-end searches;
rollout estimates cannot assume the proxy's direct work-lookup latency is the user-visible search
latency. Only aggregate timing statistics are committed; sampled titles remain public corpus data.

The snapshot exposes two migration hazards rather than treating every row as equally wanted:

1. The eBook instance monitors every work under two authors, while only 181 works have files.
   Importing all monitored rows as active acquisition requests would create a back-catalogue flood.
2. The audiobook instance has 169 monitored editions but only one monitored work and one file.
   Edition monitoring cannot be interpreted independently of work/author policy.

B6 must therefore preserve source monitoring evidence, but it must not schedule acquisition merely
because a source row is monitored.

## Parity matrix

The normative, machine-readable matrix is
[`books-parity-matrix-v1.json`](../audits/data/books-parity-matrix-v1.json). Every currently relied-on
behavior has one of the four roadmap dispositions plus an acceptance criterion and migration
consequence:

| Behavior | Disposition | Acceptance criterion | Migration consequence |
|---|---|---|---|
| Catalog identity boundaries | `required for cutover` | Keep author, work, edition, and file identities distinct and referentially valid. | B6 resolves all four surfaces; ambiguous joins are held. |
| eBook profile | `required for cutover` | Import EPUB, AZW3, and MOBI with EPUB preferred and no conversion. | B6 maps the existing profile and files as-is. |
| Audiobook target | `required later` | Keep audiobook monitoring independent and import the captured M4B safely. | B7 adds the target/profile and adopts audio; B6 does not create an audiobook target. |
| Download clients | `already provided by Cinder` | Reuse torrent and Usenet adapters as the credential boundary. | No connector secret is imported. |
| Indexer provenance | `already provided by Cinder` | Persist release/indexer evidence through explicit book categories. | Only source history, never URLs or credentials, is adopted. |
| Completed-download lifecycle | `already provided by Cinder` | Validate and publish durably before cleanup with retry-safe state. | Transient queue state is not migrated. |
| Hardlink/copy publication | `required for cutover` | Prefer hardlink and fail safely to explicit copy. | Already-correct files are adopted without rewrite. |
| Import naming | `required for cutover` | Preserve existing filenames by default. | B6 performs no adoption rename. |
| Booklore handoff | `required for cutover` | Publish under the books root without consumer DB mutation. | Existing files are verified in place. |
| Audiobookshelf handoff | `required later` | Publish under the audiobooks root; scan failure is retryable post-commit. | B7 owns audiobook publication, scan, and migration; B6 does not publish audio. |
| Monitoring-state adoption | `required for cutover` | Preserve flags as evidence and create no acquisition before preview confirmation. | B6 imports confirmed eBook targets; B7 separately handles audiobook targets. |
| Automatic author monitoring | `required later` | Offer specific/future/all policies with count preview and separate confirmation. | B5 owns author policies; B6 only preserves source flags and enables no blanket automation. |
| Metadata provider set | `required for cutover` | Use Open Library primary plus Hardcover secondary; Google remains optional enrichment. | Store every source/provider ID with provenance. |
| Identity ambiguity | `required for cutover` | Return an explained unresolved/held result instead of first-result selection. | B6 moves or downloads nothing for unresolved items. |
| Request governance | `already provided by Cinder` | Reuse authorization, approval, quota, audit, and notification primitives. | No requester identity is invented during adoption. |
| Calibre integration | `deliberately parked` | No Calibre adapter is needed for the observed consumer topology. | B6 never writes Calibre or invokes `calibredb`. |
| Automatic upgrades/conversion | `deliberately parked` | No automatic quality upgrade or format conversion in the first release. | Current accepted files are adopted as-is. |

## Data boundaries

The canonical model is four distinct identity layers plus explicit relationships:

| Boundary | Cinder meaning | Stable identity | Cardinality and ownership |
|---|---|---|---|
| **Author / contributor** | A person or organization credited to a work or edition. | Internal Cinder ID plus namespaced provider IDs. | Works have many contributors through a join carrying role and order. No single `author_id` shortcut. |
| **Work** | The abstract intellectual work users discover, request, and monitor. | Internal Cinder ID plus provider work IDs. | A work has many editions, optional ordered memberships in many series, and independent desired media kinds. |
| **Edition** | A publication/recording manifestation: language, format, publisher, date, ISBN/ASIN, abridgement, or translation. | Internal Cinder ID plus provider edition IDs and normalized identifiers. | Belongs to one work; may credit edition-specific contributors such as translator or narrator. |
| **File** | One imported physical asset. | Internal Cinder ID; checksum is evidence, never catalog identity. | Belongs to one edition and one media kind. A work/edition may have multiple files and multipart audio. |

Additional locked boundaries:

- Provider IDs are namespaced tuples (`provider`, `kind`, `foreign_id`), never untyped integers.
- Contributor rows are role-aware (`author`, `editor`, `translator`, `narrator`, and other provider
  roles) and preserve provider ordering where available.
- Series membership is a join with a decimal/string position; a work can belong to multiple series.
- `ebook` and `audiobook` are media kinds attached to editions/files and desired assets. They are
  not separate copies of the author/work catalog.
- A title, ISBN, ASIN, path, or filename alone is insufficient for automatic identity resolution.
- Alternate/translated edition titles remain edition metadata; they do not overwrite a work title
  without provider-backed identity evidence.

### Author identity and aliases

Author display names and aliases are mutable metadata on a namespaced contributor identity; they
are never the join key. Aliases can aid search but cannot merge people automatically.

### Work and edition identity

Work identity is the discovery/request boundary. Edition identity carries publication, language,
format, and external publication identifiers; neither boundary may collapse into the other.

### Multiple contributors

The work/contributor and edition/contributor relationships are many-to-many, role-bearing, and
ordered. Missing provider credits remain explicitly incomplete rather than synthesized.

### Series and position

Series membership is separate from work identity and preserves provider position as a value that
can represent integer, fractional, or textual ordering without lossy coercion.

## Monitoring semantics

Monitoring is explicit at `(work, media_kind)`. Author monitoring is only a bulk policy that can
seed work-monitor decisions; it is not a permanent implicit request for every bibliography item.

Locked states:

- `unmonitored`: visible catalog item; no automated search or upgrade.
- `monitored`: eligible for missing-item search for the selected media kind.
- `available`: at least one accepted file exists; monitoring may remain on for upgrades.
- `held`: operator-visible identity, metadata, disk, or import conflict; never auto-grab.

Migration stores source author/work/edition flags as evidence, then derives no active acquisition
until an operator previews and confirms the import. New authors default to no blanket
back-catalogue monitoring. A work can monitor eBook, audiobook, both, or neither independently.
A monitored edition never overrides an unmonitored work/media pair.

## Quality and format policy

Quality profiles are media-kind specific and immutable by reference on grabs/imports:

- `ebook`: accepts EPUB, AZW3, and MOBI initially, with EPUB preferred. Container format,
  language, DRM evidence, and completeness are separate facts. A different edition is an upgrade
  only when the profile says so.
- `audiobook`: accepts M4B and common multipart audio containers in later acquisition milestones,
  with M4B preferred for the captured deployment. Bitrate/codec, abridgement, narrator, language,
  and part completeness are distinct facts.

A release never satisfies both profiles accidentally. Profile evaluation records the matching
edition/media kind and the reason for acceptance. Unknown or contradictory formats fail closed to
manual review.

## indexer/release matching

Both torrent and Usenet remain supported protocol classes. Indexers and download clients are
adapter-backed configuration; their credentials and base URLs do not belong in catalog rows or
fixtures.

Release matching proceeds from parsed title/contributors/series/position/media format to a
candidate work and edition. Provider work/edition IDs are strongest; ISBN/ASIN are edition-level
signals. Fuzzy title matching can rank candidates but cannot authorize a grab when identities
conflict. Co-authored, omnibus, anthology, translated-title, and abridged/unabridged ambiguity must
produce an explained rejection or `held` state rather than a silent fallback. The exact release,
profile snapshot, protocol, and decision reasons are persisted for auditability.

## Import naming

Parity keeps completed-download handling and hardlink preference. The importer must still be safe
when hardlinking is impossible: copy/move fallback is explicit, disk space is checked, the final
file is fsynced/verified before source cleanup, and failures are retry-safe.

Automatic renaming remains **off** for migration parity. **Preserve release filenames** is the B0
default: existing filenames are preserved during
adoption. New imports may compute the dormant Bookshelf template for preview, but cannot apply it
until an operator enables a Cinder naming policy. Illegal path components are sanitized, and no
provider title is allowed to escape the configured library root.

Final roots are role-based, not host-specific strings:

- `books` for eBook assets;
- `audiobooks` for audiobook assets.

The 100 MB captured minimum is migration evidence, not an adequate universal default; B6 must use
asset-size-aware headroom and fail before mutating files when free space is insufficient.

## Consumer handoff

Cinder owns acquisition and final library placement. Consumers remain read/scan surfaces.

### Booklore handoff

Booklore reads the `books` root after a durable import commit.

### Audiobookshelf handoff

Audiobookshelf reads the `audiobooks` root after a durable import commit.

A successful import is committed only after the final path is durable. Consumer notification or
rescan happens after commit and is retryable; consumer downtime cannot roll back or duplicate the
import. Cinder never writes consumer databases. Moving/renaming an existing asset requires the same
crash-safe filesystem protocol as a new import.

## Metadata provider decision

The B0 corpus rejects the roadmap's initial Open Library plus optional Google Books pair as a
standalone cutover source. The frozen evaluation made one bounded search per provider for all 40
operator-confirmed cases:

| Provider path | Reliably resolved | Operational evidence |
|---|---:|---:|
| Open Library primary | 31/40 (77.5%) | 40 bounded searches completed |
| Google Books keyless fallback | not measurable | 40/40 requests returned HTTP 429 |
| Open Library plus captured Hardcover/bookinfo evidence | 37/40 (92.5%) | Hardcover adds 6 reliable identities |

The acceptance threshold is at least 90% reliable work identity with zero silent first-result
fallbacks; unresolved cases are allowed only as explicit ambiguity/unavailable outcomes. Therefore
B2 must implement **Open Library as primary plus a Hardcover-compatible secondary adapter**. Google
Books remains optional enrichment: keyless evaluation was operationally unavailable (40/40 HTTP
429), so no theoretical coverage was inferred from failed requests and it is not mandatory for
cutover. The three remaining unresolved public cases (`count-monte-cristo`,
`leviathan-wakes`, and `time-war`) must stay explained unresolved states until operator correction
or stronger evidence; adding Hardcover does not authorize a guess.

This decision is about corpus sufficiency, not provider popularity. All normalized fields retain
per-provider provenance, and provider IDs are never equated across adapters without recorded
identity evidence.

## Provider corpus and observed gaps

The operator confirmed a curated public corpus rather than committing household titles. The 40
cases cover all roadmap categories and intentionally overlap categories:

| Category | Cases |
|---|---:|
| Single novels | 7 |
| Long series | 9 |
| Explicit series position | 1 |
| Co-authored works | 7 |
| Collective pen name | 1 |
| Anthologies | 4 |
| Translated/alternate editions | 8 |
| Omnibuses | 4 |
| eBook-bearing accepted responses | 27 |
| Audiobook-bearing accepted responses | 11 |
| Conflicting/multiple editions | 12 |
| Explicit multi-edition expectation (`min_editions >= 2`) | 1 |
| Missing ISBN | 1 |
| Duplicate title | 1 |
| Unicode/punctuation | 1 |
| Future release | 1 |
| Already-correct file | 1 |
| Irreconcilable identity | 1 |

The frozen proxy evidence yields 33 identity-acceptable responses and 7 fail-closed responses. A
rejected response is a successful B0 observation, not a fixture failure: it means the proxy either
returned no reliable work, returned a wrong fallback, exposed the right search ID but failed its
work lookup, or attributed an omnibus to the wrong contributor. Future discovery must surface
that state instead of accepting the fallback.

Contributor completeness is independently labeled. Twelve cases omit one or more expected public
contributors—including co-authors, editors, or translators—even when work identity is acceptable.
This is why the data model supports many role-bearing contributors while the provider adapter must
preserve an explicit "incomplete" signal. It must not invent missing identities.

Series ordering has the same explicit gap: the operator-confirmed `eye-of-the-world` case expects
`The Wheel of Time` position `1`, while every captured Hardcover series entry omits position. B2
must preserve that expectation as incomplete/operator-confirmed evidence and must not parse a
position from title text.

`provider-v1.json` is intentionally compact: it freezes search IDs, selected work/edition identity
fields, provider failures, and the B0 assessment, while dropping descriptions, ratings, and image
URLs that do not affect the contract.

## adoption/migration implications

### Migration consequence

B6 eBook migration is a read-only preview followed by an idempotent import; it is not a database
copy. The separately captured audiobook instance follows the same safety contract in B7, not in the
B6 eBook cutover.

1. Capture source rows and source IDs without changing Bookshelf.
2. Resolve authors, works, editions, and files into separate Cinder identities.
3. Preserve source flags and source paths as migration evidence, not ongoing configuration.
4. Detect duplicate files by durable file evidence plus edition identity; never by filename alone.
5. Put ambiguous contributor, edition, omnibus, or path mappings into `held` preview rows.
6. Show counts by media kind and the exact monitoring states that would be created.
7. Require operator confirmation before creating active monitor/request state.
8. Import transactionally and make retries no-op for already imported source identities.
9. Leave Bookshelf and consumer libraries untouched on validation failure.
10. Retain a reversible mapping report until decommission acceptance is complete.

There is no cross-provider ID equivalence without recorded evidence. If a future Cinder provider
uses different IDs, migration stores both the Bookshelf source identity and the resolved provider
identity with provenance.

## Security and privacy

- API keys, download-client credentials, indexer credentials, hostnames, addresses, and personal
  paths are excluded from git and logs.
- Raw inventory remains local with owner-only permissions.
- Test fixtures use public corpus metadata or synthetic remapped Bookshelf records.
- API adapters redact authentication headers and URL query secrets before telemetry.
- Import path construction rejects traversal, absolute child paths, NULs, and root escape.
- Provider ambiguity, malformed JSON, unexpected response shape, and identifier conflicts fail
  closed to an explained unavailable/held state.

## B0 acceptance and handoff

B0 is complete when the repository test proves that:

- the secret-free aggregate matches both captured instances;
- the public corpus has exactly 40 unique, operator-confirmed cases and covers every required
  category;
- every corpus case links to a frozen provider response and explicit accept/reject outcome;
- the sanitized Bookshelf fixture preserves author/work/edition/file/settings API shapes without
  deployment data; and
- every parity boundary named by the roadmap is locked in this contract.

**No books production code may land before B0** satisfies those checks; this milestone freezes
evidence and contracts only.

B1 should consume these artifacts as constraints, not redesign them. In particular it must model
many contributors, work/edition separation, series memberships, media-kind-specific monitoring,
quality-profile references, and namespaced provider identities before implementing discovery.
