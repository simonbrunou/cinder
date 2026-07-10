---
name: nix-bootstrap
description: Bootstrap or repair the cinder dev toolchain after a clone or an Elixir/OTP version change — clears a stale _build, installs hex/rebar into the active namespace, fetches deps, and runs the suite. Use when mix fails with NIF/"corrupt atom table" errors, after switching Elixir/OTP, or on a fresh machine.
disable-model-invocation: true
---

# nix-bootstrap

Bring the cinder dev toolchain into a known-good state under the Nix flake dev shell.
This is the procedure that fixes the gotcha after an Elixir/OTP bump (e.g. 1.19/OTP28 →
1.20/OTP29): `_build` and the `~/.mix/elixir/<elixir>-otp-<otp>` hex/rebar archives are
keyed to a specific OTP, so they must be reset.

Run these steps in order, stopping to report if any step fails.

## 1. Confirm the dev shell is active

```bash
elixir --version    # should print the flake's Elixir + "Erlang/OTP NN"
```

If `elixir` is **not found**, the flake dev shell isn't loaded. Fix it first:
- `direnv allow` in the project dir (the `.envrc` runs `use flake`), then re-open the shell; or
- prefix every command below with `nix develop --command ` (nix lives at
  `/nix/var/nix/profiles/default/bin/nix` if `nix` itself isn't on PATH).

Confirm the version matches CI (`.github/workflows/ci.yml` — currently **Elixir 1.20 / OTP 29**).

## 2. Clear the OTP-keyed build artifacts

```bash
rm -rf _build
```

Skip only if you're certain `_build` was last compiled under the *current* OTP. When in
doubt, clear it — a mismatched `_build` surfaces as NIF load failures / "corrupt atom table"
from `exqlite`/`bcrypt_elixir`.

## 3. Bootstrap hex + rebar into the current namespace

```bash
mix local.hex --force && mix local.rebar --force
```

Needed because nixpkgs `elixir` doesn't ship hex, and a new OTP version means a fresh
`~/.mix/elixir/<x>-otp-<y>` namespace with no cached archives. (First run needs network.)

## 4. Fetch dependencies

```bash
mix deps.get
```

`git` must be on PATH (the flake provides it) — `heroicons` is a `github:` dep.

## 5. Verify green

```bash
mix test
```

This is the project alias: `compile --warnings-as-errors` → `format --check-formatted` →
`credo --strict` → `ecto.create`/`ecto.migrate` → the suite. A clean run confirms the C NIFs
compiled under the new OTP and the whole stack is healthy.

Report the final test count + any failures. Compile-time warnings from **dependencies**
(e.g. Elixir 1.20 deprecation notices) are expected and do not fail the build — cinder's own
code must compile clean under `--warnings-as-errors`.
