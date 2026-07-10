---
name: "source-command-claude-status"
description: "Check Codex installation status and configuration"
---

# source-command-claude-status

Use this skill when the user asks to run the migrated source command `claude-status`.

## Command Template

# Codex Installation Status

I'll check the status of Codex integration in your project.

## Installation Overview

! echo "=== Codex Installation Status ===" && \
  if [ -f ".Codex.exs" ]; then \
    echo "✓ Configuration file: .Codex.exs"; \
  else \
    echo "✗ No .Codex.exs configuration file"; \
  fi && \
  if [ -d ".Codex" ]; then \
    echo "✓ Codex directory: .Codex/"; \
  else \
    echo "✗ No .Codex directory"; \
  fi

## Configuration Details

### Hooks Configuration

! echo -e "\n=== Hooks ===" && \
  if [ -d ".Codex/hooks" ]; then \
    echo "Installed hooks:" && ls .Codex/hooks/ | sed 's/^/  - /'; \
    echo -e "\nConfigured in .Codex.exs:" && \
    grep -A10 "hooks:" .Codex.exs 2>/dev/null | head -15; \
  else \
    echo "No hooks installed"; \
  fi

### Subagents

! echo -e "\n=== Subagents ===" && \
  if [ -d ".Codex/agents" ]; then \
    echo "Installed subagents:" && ls .Codex/agents/*.md 2>/dev/null | xargs -I {} basename {} .md | sed 's/^/  - /'; \
  else \
    echo "No subagents installed"; \
  fi

### Nested Memories

! echo -e "\n=== Nested Memories ===" && \
  grep -A20 "nested_memories:" .Codex.exs 2>/dev/null || echo "No nested memories configured"

! echo -e "\nGenerated AGENTS.md files:" && \
  find . -name "AGENTS.md" -not -path "./.git/*" -not -path "./_build/*" -not -path "./deps/*" 2>/dev/null | sed 's/^/  - /'

### MCP Servers

! echo -e "\n=== MCP Servers ===" && \
  if [ -f ".mcp.json" ]; then \
    echo "MCP configuration exists:" && \
    cat .mcp.json | grep '"name"' | sed 's/.*"name"://; s/[",]//g' | sed 's/^/  - /'; \
  else \
    echo "No MCP servers configured"; \
  fi

### Settings

! echo -e "\n=== Local Settings ===" && \
  if [ -f ".Codex/settings.json" ]; then \
    echo "Settings file exists with configurations:" && \
    cat .Codex/settings.json | grep -E '^\s*"[^"]+":' | sed 's/^/  /'; \
  else \
    echo "No local settings file"; \
  fi

## Usage Rules Status

! echo -e "\n=== Usage Rules ===" && \
  echo "Checking for usage_rules dependency..." && \
  mix deps | grep usage_rules || echo "usage_rules not installed"

! echo -e "\nAvailable usage rules:" && \
  mix usage_rules.sync --list 2>/dev/null | head -10 || echo "Cannot list usage rules"

## Quick Actions

Based on the status above:

! if [ ! -f ".Codex.exs" ]; then \
    echo "→ Run '/Codex/install' to set up Codex integration"; \
  elif [ ! -d ".Codex/hooks" ]; then \
    echo "→ Run 'mix Codex.install' to install configured components"; \
  else \
    echo "→ Run '/Codex/install --yes' to update installation"; \
    echo "→ Run '/memory/nested-sync' to update nested memories"; \
    echo "→ Run '/hooks' to manage hooks"; \
  fi

## Health Check

! echo -e "\n=== Health Check ===" && \
  errors=0 && \
  if [ -f ".Codex.exs" ]; then \
    echo "✓ Configuration exists"; \
  else \
    echo "⚠ Missing .Codex.exs" && errors=$((errors+1)); \
  fi && \
  if [ -d ".Codex/hooks" ] && [ -f ".Codex.exs" ]; then \
    echo "✓ Hooks match configuration"; \
  elif [ -f ".Codex.exs" ] && grep -q "hooks:" .Codex.exs; then \
    echo "⚠ Hooks configured but not installed" && errors=$((errors+1)); \
  else \
    echo "✓ No hooks expected"; \
  fi && \
  if [ $errors -eq 0 ]; then \
    echo -e "\n✅ Codex installation is healthy"; \
  else \
    echo -e "\n⚠ Found $errors issue(s) - run '/Codex/install' to fix"; \
  fi
