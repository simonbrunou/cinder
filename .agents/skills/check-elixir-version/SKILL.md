---
name: check-elixir-version
description: Check the active Elixir and Erlang/OTP versions against Cinder's Nix flake and CI requirements. Use after a toolchain change, on a fresh checkout, or when compilation reports BEAM, NIF, or version incompatibilities.
---

# Check Elixir version

1. Run `elixir --version` inside the active Nix dev shell.
2. Read the required Elixir version from `mix.exs` and the CI versions from
   `.github/workflows/ci.yml`.
3. Report exact mismatches. Do not modify the toolchain unless the user asks for an upgrade.
4. If `_build` came from another OTP version, recommend the `nix-bootstrap` skill.

If `elixir` is unavailable, run the checks with `nix develop --command` or ask the user to allow
direnv. Do not introduce another version manager.
