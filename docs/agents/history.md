# History and status

- Cinder is released; `CHANGELOG.md` has the versions. Work is incremental (issues, fixes,
  one-off features) and there is no current phase.
- The roadmap items still open are operator actions, not code: the two-week Readarr-stopped
  dogfood window, then the Bookshelf decommission after sign-off. See
  `docs/books-dogfood-checklist.md` and `docs/readarr-migration.md`.
- Books have no automatic release search, by design. An admin picks the release in manual search
  until a measured corpus-precision threshold is met. Adding automatic selection is a product
  decision with that prerequisite, not a bug fix.
- `ROADMAP.md` is the build record (Phases 0 to 5, M0 to M8, A0 to A6, B0 to B8), not a live
  plan. It runs past 1,100 lines: read only the section behind the decision you are researching.
- `specs/NNN-slug/` is the frozen record of features planned with Spec Kit. Each holds
  `spec.md`, `plan.md`, `tasks.md`, and its design rationale in `research.md`. Tests read files in
  it, so it stays. New specs are Forgejo issues (see [workflow.md](workflow.md)).
- `docs/audits/` holds the dated audits.
