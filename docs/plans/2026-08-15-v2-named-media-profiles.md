# v2.0: named media profiles

Council review: 2 rounds - consensus sound; SQLite NOCASE is intentionally ASCII-only and path
identity remains lexical (`Path.expand`) like the existing safety boundary.

**Status:** implemented for v2.0.0 on 2026-08-15; final release gate recorded in the merge commit.

## Goal

Replace the fixed Standard/Anime destination choice with operator-named movie and TV profiles.
Each profile has a name, media kind, Standard or Anime handling, and an optional library root.
Titles and requests reference the profile by id; existing selections migrate without changing
their handling.

## Compatibility boundary

- Keep the current Standard/Anime handling engine and global release rules. A named profile chooses
  one of those proven engines; it does not duplicate the scorer or Anime policy.
- Keep media-server scans per media kind. Jellyfin already refreshes globally and Plex's configured
  movie/TV section is the stable provider contract.
- A blank profile root falls back to the matching existing Standard/Anime root. Existing installs
  therefore keep the same paths after migration.
- Keep the legacy handling columns synchronized during v2 so background jobs and API v1 clients do
  not break while profile identity becomes the source of operator intent.
- Existing Auto titles and requests with no proposed handling keep a null profile id. Approval UI
  continues to default an unselected request to the seeded Standard profile.

## Integrity and safety rules

- Profile names are trimmed, non-empty, and unique case-insensitively within their media kind.
  Handling and kind have database checks. Nonblank roots are absolute, normalized, not `/`, and
  unique by expanded path within a kind; distinct nested roots are allowed and scanned
  most-specific first.
- Context-only root uniqueness and last-profile retention use SQLite immediate transactions so
  concurrent admin writes cannot pass the same check. Relative or non-normalized submitted paths
  are rejected before expansion rather than silently rewritten.
- A referenced profile may be renamed, but its kind, handling, and root cannot change. Referenced
  profiles cannot be deleted, and each kind must retain at least one profile.
- Assignment is a context choke-point: it rejects unknown or wrong-kind ids and synchronizes the
  legacy handling field in the same transaction. Request creation, auto-approval, single approval,
  and bulk approval all use that validation before mutating request/title state.
- Adoption revalidates the profile and root containment when committing. A unique explicit named
  root assigns that exact profile; a shared legacy fallback root cannot infer a blank profile and
  retains existing Auto/handling behavior. Ambiguous explicit roots fail closed.
- API v1 rejects payloads containing both `profile_id` and legacy `media_profile`. Profile ids must
  be positive, present, and match the target kind; request output includes
  `profile: {id, name, kind, handling}` from the live association (so a rename is reflected) while
  legacy input remains accepted.
- Profile administration stays inside the existing admin LiveView session. Forms use labelled
  controls, inline changeset errors, defensive id parsing, and confirmed deletion with clear
  in-use/last-profile errors.

## Work

1. Add and seed the profile model, foreign keys, constraints, migration backfill, and assignment
   choke-points.
2. Route imports, adoption, deletion fencing, and recovery through named roots.
3. Add admin profile management and dynamic request/title selectors while preserving the approval
   gate and legacy API inputs.
4. Bump to 2.0.0, document migration/rollback behavior, refresh translations and the graph, then
   run the full project gate and focused safety reviews.

## Done when

- A household can create a named movie or TV profile and assign it during a request or on a title.
- Wrong-kind and unknown profiles are rejected without changing request/title state.
- Existing explicit Standard/Anime titles and requests are backfilled deterministically; Auto
  titles and nil proposed requests remain null.
- A named root is used for import and adoption; blank roots preserve existing behavior.
- Referenced profiles cannot be deleted, and every managed destination remains root-fenced.
- `mix test` passes.

Rollback is association-lossy but handling-safe: v2 keeps the legacy handling columns synchronized,
so rolling back drops names and custom destinations without changing Standard/Anime engine choice.
