# Issue tracker: Forgejo

Issues and specs for this repo live as Forgejo issues on `git.sbrn.eu/simonbrunou/cinder` (the
`origin` remote). The `github` remote is a push-disabled mirror. Its issues are still enabled, but
nothing new gets filed there.

Use the [`fj`](https://codeberg.org/forgejo-contrib/forgejo-cli) CLI for reads, PRs and
assignments. Every other issue write goes through the `forgejo-issues` skill's script, written
`forgejo.py` below (`python3 -I ~/.agents/skills/forgejo-issues/scripts/forgejo.py`): it fails
on an unknown label, sets labels in the same call that creates the issue, and reads every write
back. Name the repo on every `fj` command: T3 worktree branches have no upstream, so a bare
`fj issue ...` fails with `no repo info specified`.

- `fj issue <cmd> -R origin ...`. `-R` goes after the subcommand.
- `fj -H git.sbrn.eu pr ...` and `fj -H git.sbrn.eu repo labels simonbrunou/cinder ...`. `-H`
  goes before the subcommand.

`fj` (v0.7.0) has no JSON output. Its dependency commands (`fj issue depend list -R origin <n>`,
`depend add`, `depend remove`, `fj issue block ...`) are new and only `list` has been tried, so
add a dependency with `forgejo.py depend` (**Blocking** below). For other JSON reads, call the
Forgejo REST API with the token `fj` already stores:

```sh
FJ_TOKEN=$(jq -r '.hosts["git.sbrn.eu"].token' ~/.local/share/forgejo-cli/keys.json)
API=https://git.sbrn.eu/api/v1/repos/simonbrunou/cinder
curl -s -H "Authorization: token $FJ_TOKEN" "$API/issues/<n>"
```

Never print the token. The `curl ...` shorthand below means the authenticated call above. `fj`
output contains U+2068/U+2069 isolate characters that break plain `grep`; check results through
the API with `jq`.

## Conventions

- **Create an issue**: `forgejo.py create cinder "<title>" <file> --labels <a,b>`. Write
  multi-line bodies to a temp file with a heredoc.
- **Read an issue**: `fj issue view -R origin <n>` for the body, `fj issue view -R origin <n>
  comments` for the comments. For JSON with labels:
  `curl ... "$API/issues/<n>" | jq '{number, title, body, state, labels: [.labels[].name]}'`.
- **List issues**: `fj issue search -R origin --state open --labels <label>`. For JSON:
  `curl ... "$API/issues?state=open&type=issues&labels=<label>&limit=50" | jq '[.[] | {number, title, labels: [.labels[].name]}]'`.
  Keep `type=issues`, because without it the endpoint also returns PRs.
- **Make an issue a child of a parent**: Forgejo has no sub-issues. Put `Part of #<parent>` at the
  top of the child body and add the child to a task list in the parent body.
- **Comment on an issue**: `forgejo.py comment cinder#<n> <file>`.
- **Apply / remove labels**: `forgejo.py labels cinder#<n> --add <a,b> --remove <c>`.
- **Edit an issue body**: `forgejo.py body cinder#<n> > old.md`, edit a copy, then
  `forgejo.py edit cinder#<n> new.md --expect old.md`, which refuses when another session edited
  the body meanwhile.
- **Close**: `forgejo.py comment cinder#<n> <file>` for the reason, then
  `forgejo.py close cinder#<n>`. Always give the reason.

Renovate owns the "Dependency Dashboard" issue (#629). Leave it out of triage.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature
requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `fj pr`
equivalents:

- **Read a PR**: `fj -H git.sbrn.eu pr view simonbrunou/cinder#<n>`, with `comments` or `diff`
  appended for the rest.
- **List external PRs for triage**: `curl ... "$API/pulls?state=open" | jq '[.[] | select(.user.login | IN("simonbrunou", "renovate") | not) | {number, title, author: .user.login, labels: [.labels[].name]}]'`.
- **Comment / label / close**: `fj -H git.sbrn.eu pr comment|edit|close simonbrunou/cinder#<n>`.

Forgejo shares one number space across issues and PRs, so a bare `#42` may be either. Resolve it
with `curl ... "$API/issues/42" | jq .pull_request`: a non-null value means a PR.

## When a skill says "publish to the issue tracker"

Create a Forgejo issue on `origin`.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets. The
`wayfinder:*` labels exist on the repo (`map`, `research`, `prototype`, `grilling`, `task`); check
with `fj -H git.sbrn.eu repo labels simonbrunou/cinder view`.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog
  body. Create it with `forgejo.py create cinder "<title>" <file> --labels wayfinder:map`.
- **Child ticket**: an issue with `Part of #<map>` at the top of its body, listed in a task list in
  the map body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once
  claimed, the ticket is assigned to the driving dev.
- **Blocking**: Forgejo's native issue dependencies, enabled on this repo and visible in the UI.
  Mark `<child>` as blocked by `<blocker>` with `forgejo.py depend cinder#<child> cinder#<blocker>`.
  A ticket is unblocked when every blocker is closed.
- **Frontier query**: `forgejo.py frontier cinder#<map>` lists the map's open tickets in map
  order, each marked frontier (no assignee, no open blocker), claimed or blocked. The first
  frontier line is the next ticket.
- **Claim**: `fj issue assign -R origin <n> simonbrunou`, the session's first write
  (`forgejo.py` has no assign command).
- **Resolve**: `forgejo.py comment cinder#<n> <answer-file>`, then `forgejo.py close cinder#<n>`,
  then append a context pointer (gist + link) to the map's Decisions-so-far.
