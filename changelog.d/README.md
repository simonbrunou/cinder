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

`mix test` parses every fragment (`test/code_health_test.exs`), so a malformed one fails on its
own PR. A release runs `mix cinder.changelog.release`, which folds every fragment into the new
dated section of `CHANGELOG.md` and deletes it; see "Releasing" in `CONTRIBUTING.md`.
