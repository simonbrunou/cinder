---
name: "source-command-mix-deps-check"
description: "Check for outdated dependencies and available updates"
---

# source-command-mix-deps-check

Use this skill when the user asks to run the migrated source command `mix-deps-check`.

## Command Template

# Dependency Status Check

I'll check your project for outdated dependencies and available updates.

## Current Dependencies

! mix deps

## Checking for Outdated Dependencies

! mix hex.outdated

## Lock File Status

! mix deps.get && echo "Dependencies are in sync" || echo "Dependencies need to be fetched"

Based on the output above, I can help you:
1. Identify which dependencies have newer versions available
2. Understand the version constraints in your mix.exs
3. Plan an upgrade strategy
4. Use `/deps-upgrade` command to perform the actual upgrades
