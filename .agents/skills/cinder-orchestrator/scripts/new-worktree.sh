#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <repo> <branch> <worktree-dir> [base-ref]" >&2
  exit 2
fi

repo=$1
branch=$2
worktree_dir=$3
base_ref=${4:-origin/main}

command -v git >/dev/null 2>&1 || {
  echo "missing required command: git" >&2
  exit 127
}

[[ -d "$repo/.git" || -f "$repo/.git" ]] || {
  echo "not a git worktree: $repo" >&2
  exit 2
}

if [[ -e "$worktree_dir" ]]; then
  echo "worktree path already exists: $worktree_dir" >&2
  exit 2
fi

# Refresh the default base without altering the operator's current checkout.
if [[ "$base_ref" == "origin/main" ]]; then
  git -C "$repo" fetch origin main
fi

mkdir -p "$(dirname "$worktree_dir")"
git -C "$repo" worktree add -b "$branch" "$worktree_dir" "$base_ref"

printf '%s\n' "$worktree_dir"
