# Books B1 — media-kind capability registry and profile foundation

**Date:** 2026-08-24
**Roadmap item:** [`readarr-replacement-roadmap`](2026-08-20-readarr-replacement-roadmap.md), B1
**Contract:** [`books parity contract`](../specs/2026-08-20-books-parity-contract.md)
**Branch:** `feat/books-b1-media-kind-foundation`
**Council review:** n/a

## Goal

Make the frozen `:ebook` and `:audiobook` media kinds first-class registry entries that carry
**no** video assumptions, with separate `:books` and `:audiobooks` filesystem root roles, so B2+
can build the books catalog without forking movie/TV behavior. Existing movie/TV behavior must stay
byte-for-byte identical at every external boundary.

## The problem this milestone actually solves

`lib/cinder/library.ex:49-54` claims a new media type "is one entry here, not a fork". That is
false today. A survey of `lib/` found that adding two atoms to `Library.kinds/0` would, with no
further edits:

- generate 18 video-shaped settings keys (`ebook_preferred_resolutions`, `ebook_min_size`,
  `ebook_anime_library_path`, `ebook_upgrade_cutoff`, …) plus two Plex section fields;
- render the full resolution/Blu-ray-source/blocked-term release form for books in `/settings`;
- make both book roots **mandatory** in first-run setup (`setup_live.ex:20`) and red on `/status`
  (`health.ex:101`);
- make both Plex sections mandatory for the aggregate Plex health check (`plex.ex:221`);
- feed books into the media-server reconciler every poll, where a non-movie kind is routed to
  `Series` (`media_server_reconciliation.ex:19`) and raises `FunctionClauseError` at its guard;
- authorize book roots as subtitle write/delete destinations (`subtitles.ex:721,725`);
- raise `FunctionClauseError` from `Profiles.list_profiles/1`, `profiles_live.ex:270`, and
  `library_live.ex:255`;
- be rejected by the SQLite `media_profiles_kind_valid` CHECK before any of that.

So B1 is not "add two atoms". It is: **split "media kind" from "video media kind"**, give book
media only the capabilities it explicitly declares, and keep the contract's separate filesystem
root-role axis explicit. The registry keys are the frozen `media_kind` values that B2 editions and
files will use; `root_role` is a separate field, not another spelling of the registry key.

## Design

### 1. `Cinder.LibraryKind` — the registry

One module, one literal map, three capabilities. Nothing speculative: every field below has a
consumer in this diff.

```elixir
@kinds [
  movies:    %{video?: true,  handlings: [:standard, :anime], label: "Movies",     root_role: :movies},
  tv:        %{video?: true,  handlings: [:standard, :anime], label: "TV",         root_role: :tv},
  ebook:     %{video?: false, handlings: [:standard],         label: "Ebooks",     root_role: :books},
  audiobook: %{video?: false, handlings: [:standard],         label: "Audiobooks", root_role: :audiobooks}
]
```

Public API: `all/0`, `video/0`, `video?/1`, `handlings/1`, `handling?/2`, `label/1`,
`root_role/1`. The key is the media kind; `root_role/1` is the distinct filesystem axis. They
coincide for video and diverge for `:ebook` → `:books`. Pure literal — read at config-eval time,
so it must not touch Application env or Repo (same constraint the current `@kinds` carries).

`Cinder.Library.kinds/0` keeps returning `[:movies, :tv]`, now delegating to `LibraryKind.video/0`.
**This is the whole trick:** every existing per-kind derivation (Plex sections, size bands,
release policy, reconciler, disk telemetry, setup gate) iterates `Library.kinds/0` and therefore
stays byte-for-byte identical. Books opt in explicitly, one site at a time.

`@kind_labels` in `Cinder.Settings.Registry` is deleted in favour of `LibraryKind.label/1`; the
`String.capitalize/1` fallback goes with it (it would have produced the untranslatable
`"Ebook"`/`"Anime_audiobook"` strings `dashboard_live.ex:309` and `health.ex:102` render today).

### 2. Profiles gain book media kinds, `:standard` only

- `Profile.kind` enum: `[:movies, :tv, :ebook, :audiobook]`.
- Changeset validates `handling` against `LibraryKind.handlings(kind)` — an `:anime` book profile
  is a changeset error, not a raise (`profiles_live.ex:243` currently offers Anime for any kind).
- Changeset gains `check_constraint(:kind, name: :media_profiles_kind_valid)` so an enum/DB
  mismatch surfaces as a field error rather than an `Exqlite.Error`.
- `Profiles.list_profiles/1` accepts `LibraryKind.all/0` instead of a hard-coded `[:movies, :tv]`.
- `profiles_live.ex` kind selector/labels come from `LibraryKind` (removes the `FunctionClauseError`
  at `:270`).

Fail-closed checks that must stay closed and get a regression test each:

- A request may not reference a book profile — `requests_profile_integrity` already accepts only
  `movie→movies` and `series|season|episode→tv`. No change; add a test that proves it aborts.
- `Profiles.assign/2` has no book clause and must keep having none until B2 has works.

### 3. Migration: rebuild `media_profiles`

SQLite cannot alter a CHECK in place. Follow the proven recipe in
`20260726234308_allow_episode_upgrade_grabs.exs` (`@disable_ddl_transaction`, pinned connection,
`PRAGMA foreign_keys = OFF`, `BEGIN IMMEDIATE`, create-copy-drop-rename, restore indexes,
`verify_foreign_keys!`, commit). Two constraint changes:

- `media_profiles_kind_valid`: `kind IN ('movies','tv','ebook','audiobook')`.
- new `media_profiles_handling_valid_for_kind`:
  `kind IN ('movies','tv') OR handling = 'standard'`.

The `media_profiles_references_integrity_update` trigger is dropped with the table and must be
re-created verbatim. `movies`/`series`/`requests` FKs point at the table by name; the rename step
must not orphan them — `verify_foreign_keys!` is the gate.

**No seed rows for book kinds.** Nothing consumes a book profile until B3; a seeded `Standard`
books profile would be scaffolding for later. Books get their profile when an operator creates
one.

### 4. Settings: root keys for all kinds, video keys for video kinds

`Cinder.Settings.Registry`:

- `flat_keys/0` → `library_path` for `LibraryKind.all/0`, derived through each kind's `root_role`;
  `anime_library_path` only for kinds whose `handlings` include `:anime`; the seven
  `@band_suffixes` only for `LibraryKind.video/0` and still derived from the media kind.
- `plex_section_fields/0` → unchanged (`Library.kinds/0`, i.e. video only).
- `library_kinds/0` → all kinds, each `%{kind:, label:, video?:}`. `video?` is what lets
  `setup_live.ex` keep requiring only movie/TV roots and lets `settings_components.ex` render the
  release-policy block only for video kinds.

`Cinder.Settings`:

- `configured_library_path/2`, the env overlay, health checks, and every root-key derivation go
  through `LibraryKind.root_role/1`. Thus media kind `:ebook` reads `books_library_path`, while
  movies and TV keep their existing keys byte-identical.
- `legacy_library_destinations/0` iterates `LibraryKind.all/0` and only looks up an Anime root for
  kinds that have one. Book roots therefore enter `library_destinations/0` and `library_roots/0`
  (needed by B4 import containment and by disk telemetry) with **zero** change while both book
  roots are unset.
- Validation: skip the min/max size band and `upgrade_cutoff` resolution validation for non-video
  kinds — those keys no longer exist for books.
- New `video_library_roots/0`: `library_roots/0` filtered to video kinds.

### 5. Keep the video boundaries video-only

- `lib/cinder/subtitles.ex:721,725`, `subtitles/manifest.ex:531,536`, `subtitles/sync.ex:1429,1438`
  and `subtitles/sync/atomic_file.ex:680` switch from `Settings.library_roots/0` to
  `Settings.video_library_roots/0`. Behaviour is identical today (no book roots exist) and stays
  identical once they do — a books root must never become a legal subtitle write destination.
- `Cinder.Health.library_checks/0` keeps one required row per video kind, and adds a row for a
  book kind **only when its root is configured**. An install that never configures books must not
  turn red — same rule the subtitles row already follows.
- `setup_live.ex` requires only `video?: true` kinds.
- The media-server reconciler, Plex/Jellyfin adapters, `post_import.ex`, the pollers, and the
  subtitle workers are untouched: they iterate `Library.kinds/0`, which never grows.

### 6. Deliberate deferrals

- **`Cinder.Books.BookTarget` and its guarded transition move to B2.** A book target is
  `(work, media_kind)` — the parity contract locks monitoring at that pair — and `works` does not
  exist until B2. A `book_targets` table with a nullable or absent `work_id` is scaffolding that
  B2 would rewrite. B1 ships the kind/profile/settings/health foundation; B2 adds the catalog and
  the target lifecycle together, where the guarded transition can actually be exercised.
- **Poller extraction: no.** The roadmap asks for a decision. `Download.Poller` and
  `Download.TvPoller` have no book caller until B4; extracting shared orchestration now is a
  refactor of two working, race-sensitive modules with zero call sites to justify it. Revisit in
  B4 with a real third consumer.
- **Download labels/categories:** unchanged. No book grab exists until B4.
- Both deferrals are recorded as amendments in the roadmap.

## TDD sequence

### RED

`test/cinder/library_kind_test.exs` — new:

1. `all/0` is exactly `[:movies, :tv, :ebook, :audiobook]`; `video/0` is exactly `[:movies, :tv]`.
2. `Library.kinds/0 == LibraryKind.video/0` (the regression fence: books must never leak into it).
3. `handlings/1` — book media is `[:standard]`; `handling?(:ebook, :anime)` is false.
4. `label/1` covers every kind with no capitalize fallback; `root_role/1` proves `:ebook` maps to
   `:books`, `:audiobook` maps to `:audiobooks`, and video roles equal their kinds.

Extensions to existing suites, each written to fail first:

5. `profile_test` / `profiles_test`: an `:ebook` profile with `handling: :standard` inserts; with
   `:anime` it returns `{:error, changeset}` with an error on `:handling` (never a raise);
   `list_profiles(:ebook)` returns it. A `:books` profile fails, and a raw SQL query proves the
   valid profile persisted `kind = 'ebook'`.
6. `settings_test`: `flat_keys/0` contains `books_library_path` and **not**
   `books_min_size`, `books_preferred_resolutions`, `books_anime_library_path`,
   `books_upgrade_cutoff`, `books_plex_section`. Add both book roots to `@env_keys`.
7. `settings_test`: with a `books_library_path` set, `library_roots/0` includes it and
   `video_library_roots/0` does not.
8. `health_test`: unset book roots produce no rows; a configured `books_library_path` produces
   one `Library (Ebooks)` row.
9. `setup_live_test`: the required-service set is unchanged by the two new kinds.
10. Request fail-closed: creating a request whose `proposed_profile_id` is a book profile aborts.

### GREEN

Smallest change that satisfies the above, in this order (each step ends `mix test` green):

1. `lib/cinder/library_kind.ex` + `Library.kinds/0` delegation + registry label swap.
2. Migration + `Profile`/`Profiles`/`profiles_live` book kinds.
3. Settings registry key derivation + `legacy_library_destinations` + validation skips +
   `video_library_roots/0`.
4. Subtitles/manifest/sync/atomic_file root-source swap.
5. Health + setup gate + settings UI conditional rendering.
6. `SettingsLabels.known/0` entries and FR gettext for the new labels, extracted **last**.

### REFACTOR / verification

- `mix test` (compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite).
- `mix gettext.extract --merge` last, after every `lib/` edit, then re-run `mix test`.
- One bounded independent review of the complete diff; fix concrete findings; re-review the fix
  diff only.
- `graphify update .` then commit, push, open PR, wait for CI.

## Done when

- [ ] `LibraryKind.all/0` has the four media kinds; `Library.kinds/0` still has two, fenced by a
      test; the separate root-role mapping is also fenced.
- [ ] An `:ebook` profile can be created with `:standard` and is refused with `:anime` at both
      the changeset and the DB CHECK.
- [ ] Configuring a book root generates no resolution, size-band, Anime-root, Plex-section,
      subtitle-root, ffprobe, or media-server-scan behavior.
- [ ] An install with no book roots has an identical `/status` panel, setup gate,
      `library_roots/0`, `legacy_library_destinations/0`, Plex section set, and disk telemetry to
      `main`.
- [ ] The settings form gains exactly two new inputs — the Ebooks and Audiobooks library roots,
      each with its test button — and nothing else. No book row appears under Releases, no book
      Anime root, no book Plex section. (The root inputs must appear: they are the only way to
      configure books, so "identical settings form" was the wrong bar.)
- [ ] A book profile created by accident stays deletable; the last-profile guard that protects
      movie/TV routing does not strand it.
- [ ] `mix test` is green.

## Review findings applied (2026-08-24)

One bounded adversarial review of the complete diff. Three defects were real and are fixed; two
reported "violations" were this plan being wrong, and the Done-when above is corrected instead.

1. **Migration left FK enforcement off on a pooled connection.** `PRAGMA foreign_keys = ON` was a
   trailing statement after a `try/rescue` that reraises, so any failure — a failed
   `BEGIN IMMEDIATE`, a rescued rebuild, or `down/0` refusing an existing book profile — returned
   the checked-out connection to the pool with foreign keys disabled. Now `try/after`. Note this
   hazard is inherited from the precedent recipe in
   `20260726234308_allow_episode_upgrade_grabs.exs`, which has the same shape.
2. **A book media kind's only profile could not be deleted.** `Profiles.delete_current/1` refuses to
   delete a kind's last profile — correct for movies/TV, which are seeded with Standard + Anime
   and cannot route without one, but books are deliberately seeded with none, so zero is their
   valid state and an accidental book profile was permanent. The guard is now video-only.
3. **The `legacy_library_destinations/0` regression test passed vacuously** — asserting "unchanged
   while unset" holds under the old implementation too. It now also configures a book root, with
   an Anime key planted in env, and asserts exactly one Standard destination appears and no Anime
   one. All three new tests were mutation-checked: reverting each implementation fails them.

### Third naming correction: media kind and root role are separate

The frozen contract defines `ebook`/`audiobook` as media kinds and `books`/`audiobooks` as
filesystem root roles. The prior correction persisted `books` as a profile kind because root keys
were mechanically derived from the kind atom. Adding explicit `root_role` metadata and routing
every root-key derivation through it removes that forced collapse: profiles persist `ebook`, while
the corresponding setting remains `books_library_path`.
