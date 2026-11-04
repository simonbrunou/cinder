#!/usr/bin/env bash
# Cinder SessionStart hook, wired in the tracked .claude/settings.json so every checkout and
# worktree runs this committed copy (cinder#1134). test/code_health/claude_session_hook_test.exs
# runs it.
# Does two things, both belt-and-suspenders around the direnv/flake dev shell:
#
#   1) Guarantees `nix` is on PATH for this Claude session even before direnv
#      activates, WITHOUT clobbering the existing PATH. $PATH is left literal so
#      Claude expands it at runtime each time it sources $CLAUDE_ENV_FILE before
#      a Bash call (settings `env` can't do this — it sets values literally).
#
#   2) Reports whether the flake dev shell is active: IN_NIX_SHELL is set (by
#      `nix develop` or direnv's `use flake`) and `elixir` on PATH is the version
#      .forgejo/workflows/ci.yml pins. Neither alone is enough. home-manager puts
#      its own Elixir on PATH (1.20.5 on 2026-11-03, against CI's 1.20.4), and any
#      other flake's dev shell sets IN_NIX_SHELL too. See cinder#983, cinder#1092
#      and nix#79.

nix_bin=/nix/var/nix/profiles/default/bin

# (1) Safe PATH prepend via the env file (no-op if the file or nix is absent).
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -x "$nix_bin/nix" ]; then
  printf 'export PATH="%s:$PATH"\n' "$nix_bin" >> "$CLAUDE_ENV_FILE"
fi

# (2) Status line.
elixir_path=$(command -v elixir 2>/dev/null)
ver=""
if [ -n "$elixir_path" ]; then
  ver=$(elixir --version 2>/dev/null | grep -i '^Elixir' | head -1)
fi

project_dir=${CLAUDE_PROJECT_DIR:-$PWD}
pin=$(grep -m1 -o 'elixir-version: "[^"]*"' "$project_dir/.forgejo/workflows/ci.yml" 2>/dev/null |
  sed 's/.*"\(.*\)"/\1/')
pinned=0
if [ -n "$pin" ]; then
  case "$ver" in "Elixir $pin "*) pinned=1 ;; esac
fi
run_hint="Run every repo command as 'nix develop ${project_dir} -c <cmd>' (git commit and git push included)."

if [ -n "${IN_NIX_SHELL:-}" ] && [ "$pinned" = 1 ]; then
  msg="Cinder flake dev shell active: ${ver} at ${elixir_path}, the Elixir CI pins; mix/elixir are usable directly."
elif [ -n "$elixir_path" ]; then
  msg="Cinder flake dev shell NOT active. Bare elixir is ${ver:-an unknown version} at ${elixir_path}; CI pins Elixir ${pin:-(no quoted elixir-version in ${project_dir}/.forgejo/workflows/ci.yml)}. ${run_hint}"
else
  msg="Cinder flake dev shell NOT active, and elixir is not on PATH. ${run_hint} nix is at ${nix_bin}/nix."
fi

# Drop control characters, JSON-escape backslashes and double-quotes, then emit as
# SessionStart context.
esc=$(printf '%s' "$msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
exit 0
