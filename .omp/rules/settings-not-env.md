---
description: Only boot-critical keys are environment variables; every other setting belongs in the Cinder.Settings registry.
globs:
  - lib/cinder/**
  - config/**
condition: 'System\.(get_env|fetch_env|fetch_env!)'
---

You are reading an environment variable. Before you add the call, read "Env vars vs
`Cinder.Settings`" in `docs/agents/configuration.md`. Only the boot-only keys listed there stay
environment variables; everything else is a `Cinder.Settings` registry entry. The section also
lists the existing env readers, so you can edit one instead of adding a new call site.
