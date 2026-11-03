# Changelog fragments

A PR with a user-visible change adds one file here instead of editing `## [Unreleased]` in
`CHANGELOG.md`, so two PRs never conflict on the changelog. A PR that changes neither the
release image nor a file a self-hoster builds or deploys with adds none, for example one touching
only `test/`, `.forgejo/workflows/`, `scripts/`, `.gitignore`, `AGENTS.md`, `docs/agents/` or
`.agents/skills/`.

- Name it `<number>-<slug>.md`: the issue number (or the PR number when there is no issue),
  then a slug in lowercase letters, digits, `-` and `_`, for example `843-merge-no-conflict.md`.
  A release folds the fragments in number order.
- Write it the way an `[Unreleased]` entry was written: one or more of the headings `### Added`,
  `### Changed`, `### Deprecated`, `### Removed`, `### Fixed`, `### Security` and
  `### Internal`, each followed by its entries. Nothing goes above the first heading, and no other
  line starting with a Markdown heading (`#` to `######` then a space) or with `##` sits at
  column 0.

```markdown
### Fixed
- **A short bold summary (#843).** What changed for the user, and what they should do about it.
```

Each sentence about what Cinder does holds on every path the fragment covers: each fallback or
other writer that still runs, and each case the code handles another way (a file with no
moviehash, an entry written before the change). Prove each one, wording taken from a code comment
or the issue's brief included, with a run that goes red when it is false, such as a throwaway
test, or cut it. On #1072 the first fragment held three such sentences, each false on some path:
three findings over two review rounds, about 22 minutes. On #871, "duplicates of one result that
disagree on whether they carry the series' id count as carrying none" came from a #699 code
comment and the triage brief. It was false for one copy with the series' id and one with none,
which settle on the series' id, and the code comment held the same clause: two re-check rounds,
about 14 minutes.

`mix test` parses every fragment (`test/code_health_test.exs`), so a malformed one fails on its
own PR. A release runs `mix cinder.changelog.release`, which folds every fragment into the new
dated section of `CHANGELOG.md` and deletes it; see "Releasing" in `CONTRIBUTING.md`.
