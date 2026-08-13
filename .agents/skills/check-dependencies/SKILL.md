---
name: check-dependencies
description: Inspect Cinder's Elixir dependencies for lock mismatches and available updates. Use when asked to check dependency health, outdated Hex packages, or whether mix.exs and mix.lock are synchronized.
---

# Check dependencies

Run inside the Nix dev shell:

```sh
mix deps
mix hex.outdated
```

Report locked, requested, and latest versions separately. Do not update `mix.exs` or `mix.lock`
unless the user asks for an upgrade. If `mix` reports a stale lock, confirm it with
`mix deps.get --check-locked` before proposing a change.
