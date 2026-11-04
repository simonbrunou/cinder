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

A sentence that says Cinder removes, cleans up or repairs something covers the paths where that
step fails or never runs. Say "tries to" or name what Cinder logs when it fails, and name what
must hold first: each condition the code checks, and each earlier step in the same call that can
stop it. On #1131 the fragment said a recovery "removes" a hidden folder and an analysis removes
the rest. Review found it false when the download's file was deleted first, when the removal
failed, and when a reset or replacement cleanup stopped `reconcile/2` before its sweep: three
review rounds, about 22 minutes.

A sentence that says Cinder no longer hangs or waits forever names the call the change bounds and
the reads it bounds there, such as "the scan" and "a download folder's file listing", never only
the trigger ("a wedged mount"). Name each step with no deadline that the claim still covers,
whether a read, a write or a delete, or narrow the claim until it no longer covers that step.
Start from the brief's **Out of scope** list, and prove it complete like any other brief wording.
A sentence about what a later call does after a timeout also holds for a call that an earlier
step ends first, and for a call that starts while the first one is still waiting out its
deadline. On #1113 the fragment first said the page "no longer scans forever on a wedged mount",
which named only the trigger while the moviehash and library-file reads have no deadline. It
then said the page "no longer waits forever on a download folder whose file listing stops
answering", which still covered the delete, and the delete has no deadline either. Last, "each
new scan of its download folder ends at once with "could not be read"" was false when a download
client failed its health check first, and for a scan started while the first was still waiting
out its deadline: three review rounds, about 35 minutes from the first finding to the last fix.

When a PR changes which release or file names a parser reads, show the change with example names
and leave the full rule to the code. A sentence that restates the rule in general words is a
claim about every name. On #1132, the fragment said in general words which years before an
episode number Cinder reads. Review found it false for a second number, a hyphen after a
bracketed year, an `S01E01` after a dotted year, a title that an omitted alias starts with, and
brackets that did not match or held more than spaces. Those five findings took three review
rounds, about 45 minutes, which one code-fix commit shared.

`mix test` parses every fragment (`test/code_health_test.exs`), so a malformed one fails on its
own PR. A release runs `mix cinder.changelog.release`, which folds every fragment into the new
dated section of `CHANGELOG.md` and deletes it; see "Releasing" in `CONTRIBUTING.md`.
