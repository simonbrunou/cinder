---
name: "source-command-memory-nested-list"
description: "List all nested memory configurations and their generated AGENTS.md files"
---

# source-command-memory-nested-list

Use this skill when the user asks to run the migrated source command `memory-nested-list`.

## Command Template

# List Nested Memory Configurations

I'll show you all configured nested memories and their corresponding AGENTS.md files.

## Current Configuration in .Codex.exs

! echo "=== Nested Memories Configuration ===" && grep -A20 "nested_memories:" .Codex.exs 2>/dev/null || echo "No nested memories configured"

## Generated AGENTS.md Files

! echo -e "\n=== Finding AGENTS.md files in project ===" && find . -name "AGENTS.md" -not -path "./.git/*" -not -path "./_build/*" -not -path "./deps/*" 2>/dev/null | while read -r file; do echo "📁 $file"; head -5 "$file" | sed 's/^/   /'; echo; done

## Directory Structure

! echo -e "\n=== Directories with AGENTS.md files ===" && find . -name "AGENTS.md" -not -path "./.git/*" -not -path "./_build/*" -not -path "./deps/*" -exec dirname {} \; | sort -u

## Usage Rules in Each AGENTS.md

! echo -e "\n=== Usage Rules per Directory ===" && find . -name "AGENTS.md" -not -path "./.git/*" -not -path "./_build/*" -not -path "./deps/*" | while read -r file; do echo "📄 $file:"; grep -E "^## .* usage$" "$file" 2>/dev/null | sed 's/^/   /' || echo "   (No usage rules found)"; done

## Summary

Based on the scan above:
- Nested memories help Codex understand directory-specific contexts
- Each directory can have its own AGENTS.md with relevant usage rules
- These are automatically synced when running `mix Codex.install`

To manage nested memories:
- Add new: `/memory/nested-add <directory> <rule1> [rule2...]`
- Remove: `/memory/nested-remove <directory>`
- Sync all: `/memory/nested-sync`
