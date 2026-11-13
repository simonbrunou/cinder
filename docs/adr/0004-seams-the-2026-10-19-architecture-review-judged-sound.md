# Seams the 2026-10-19 architecture review judged sound

The 2026-10-19 architecture review (`/improve-codebase-architecture`, #730) walked the areas changed
most since August and filed two defects and fifteen deepening candidates as #731 to #747. It also
judged six items sound: the movie, TV and book lifecycles; the poller skeleton; `AtomicFile`,
`TitleNoise` and the title guard; the video and book scorers; the library kinds' root roles, the
profile reference check, the indexer and the subtitle provider and translator; and library
destination resolution in `Settings`. A later review does not suggest deepening them again.

Each item's bold verdict and its reason are the review's, from #730's "Checked and judged fine"
list. The rest of each item is what `main` showed when this ADR was written, at 75e02c65
(2026-11-13). An "At the review" sentence says how the code stood at 9cf682b2: `lib/` as the
review read it, since no later commit touched `lib/` before its first child PR (#748) merged. A
"Since" sentence names a PR that changed the seam after the review without changing its verdict.

1. **Movies, TV and books keep separate lifecycles.** Their data models differ. A movie's status
   is a column on its row. An episode has no status column: its state derives from its pipeline
   fields and the `Cinder.Catalog.Grab` row it points at. A book target has a status of its own
   (`unmonitored`, `monitored`, `available`, `held`), and a `Cinder.Books.BookGrab` row carries
   its in-flight download. Since #737 (PR #764), every movie status write goes through
   `Cinder.Catalog.MovieLifecycle`. Since #743 (PR #790), movies, episodes, book targets and
   requests share one guarded write, `Cinder.GuardedWrite`, with one adapter per table, and since
   #789 (PR #1331) TV grabs do too. That shares the write's contract, not the lifecycles.
2. **`Cinder.Download.PollerSkeleton` already owns the tick lifecycle.** It injects the GenServer
   lifecycle (start, schedule, `poll/1`, `status/0`), the interval and the per-unit `isolate/2`
   guard into the 15 modules that use it. **Per-kind park and retry policies differ on purpose.**
   Each pipeline keeps its own failure budget and what a failure does. At the review the skeleton
   also injected one shared `@max_attempts`. Since #762 (PR #846), `TvPoller` and `BookPoller`
   each set their own, and the helpers only the TV poller used live in `TvPoller`. Since #737
   (PR #764), the movie poller hands each failure to `MovieLifecycle.record_failure/2`.
3. **`AtomicFile`, `TitleNoise` and the acquisition title guard are already deep.**
   - `Cinder.Subtitles.SidecarTransaction.AtomicFile` publishes subtitle bytes with a
     descriptor-bound exchange and verified rollback. About 1,150 lines sit behind `write/3`,
     `write/4`, `swap/3`, three cleanup and recovery functions and `reversal_id/3`. At the review
     it was `Cinder.Subtitles.Sync.AtomicFile`, about 800 lines. Since #735 (PR #759), it lives
     under the sidecar replacement transaction, `Cinder.Subtitles.SidecarTransaction`. Since #758
     (PR #799), `swap/3` publishes a fetched sidecar: an exchange when a sidecar is already
     there, and a rename onto a free name when none is.
   - `Cinder.Acquisition.TitleNoise.strip/2` decides which bare digits in a release name are
     series-position noise and which belong to the wanted title: about 250 lines behind it and
     `series_name/1`. Since #734 (PR #754), its one caller is `Cinder.Acquisition.BookScorer`.
   - The title guard, `Cinder.Acquisition.title_guard/2`, keeps the releases whose name is the
     target's. At the review it was `title_guard/3`, for a movie or a TV season. Since #746
     (PR #777), it takes one guard tuple per target kind. Since #775 (PR #840), it holds the anime
     movie guard, and `Cinder.Acquisition.ReleaseJudge` is its only caller. Since #699 (PR #870),
     it also holds the anime episode guard for TVDB-scoped results.
4. **The video `Scorer` and the book scorers are genuinely different, with about 20 shared
   lines.** `Cinder.Acquisition.Scorer` ranks playable video files: a strict resolution
   allow-list, a lenient source allow-list, a size band, preferred terms and the season
   set-cover. `Cinder.Acquisition.BookScorer` judges a book release's identity from its author,
   title and format evidence, and fails closed where `Scorer` lets an untagged release through.
   On `main`, the overlap is the release-title exclusion: the per-target blocklist checked before
   the household's blocked terms, written once in each scorer. Since #734 (PR #754, ADR 0001),
   one `BookScorer` serves both book kinds, where the review saw an e-book and an audiobook
   scorer.
5. **These seams are sound.**
   - `Cinder.LibraryKind.root_role/1` keeps the filesystem-role axis apart from the media-kind
     axis. The two coincide for movies and TV and differ for both book kinds: media kind `:ebook`
     uses root role `:books`, and `:audiobook` uses `:audiobooks`. Unchanged since the review.
   - `Cinder.Catalog.Profiles`' private `referenced?/1` and its SQL trigger,
     `media_profiles_references_integrity_update`, guard different things. The trigger refuses a
     profile `kind` or `handling` change that a movie, series, request or book target pointing at
     it would no longer fit. `referenced?/1` refuses a `kind`, `handling` or `library_path` edit,
     and a delete, while a movie, series, request, book target or book author policy points at the
     profile. Unchanged since the review.
   - The Indexer/Prowlarr seam: the `Cinder.Acquisition.Indexer` behaviour has two adapters,
     `Cinder.Acquisition.Indexer.Prowlarr` in production and a Mox mock in the tests. The
     behaviour is unchanged since the review.
   - The subtitle Provider and Translator seams: the `Cinder.Subtitles.Provider` and
     `Cinder.Subtitles.Translator` behaviours each have two adapters, `Provider.OpenSubtitles` or
     `Translator.LibreTranslate` in production and a Mox mock in the tests. `Provider` is
     unchanged since the review. Since #861 (PR #1068), `Translator` also has `configured?/0`.
6. **Library destination resolution in `Settings` is deep; it is only misplaced.**
   `Cinder.Settings` resolves the root a movie, a series' episodes or a book target imports into
   (`library_root/2`), the most specific destination holding a path
   (`library_destination_for_path/1,2`, `library_root_for_path/1`) and the managed roots
   (`library_roots/0`, `video_library_roots/0`), from the named profiles and the env roots. The
   verdict settles its depth, not its place: the review called it misplaced but did not say where
   it belongs, and filed no issue to move it. On `main` it is still in `Settings`,
   and it reads the profiles through `Cinder.Catalog`. Since #792 (PR #807), the env key it reads
   comes from the root's setting definition, through `Cinder.Settings.Overlay`.

## Considered options

The maintainer chose where this list lives on #730 (2026-10-23):

- A section in `docs/agents/architecture.md`: an agent writing code reads it, but the
  architecture review reads `GLOSSARY.md` and `docs/adr/` to skip a settled candidate.
- Leaving it in #730's body: the review reads no issue, and #730 closes once this ADR is on
  `main`.

## Consequences

A later architecture review proposes no deepening of these items while their reasons hold.
Moving item 6's resolution out of `Settings` agrees with its verdict, which calls it misplaced. To
reopen an item, a review names this ADR and the reason that no longer holds, as
`docs/agents/domain.md` "Flag ADR conflicts" asks.
