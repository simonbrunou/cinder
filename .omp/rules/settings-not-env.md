---
description: Only boot-critical keys are environment variables; every other setting belongs in the Cinder.Settings registry.
globs:
  - lib/cinder/**
  - config/**
condition: 'System\.(get_env|fetch_env|fetch_env!)'
---

You are reading an environment variable. Check which tier it belongs to.

**Boot-only keys stay environment variables** — needed before the DB/settings store is up,
or fixed per deployment:

`SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_HOST` / `PHX_SERVER` / `PORT`, `POOL_SIZE`,
`RELEASE_NAME`.

**Everything else** — external-service URLs, API keys, the media-server choice — lives in
the **`Cinder.Settings`** store: DB-backed, editable in `/settings`, overlaid on
env-as-bootstrap. Do not add a new service env var; add a registry entry in
`Cinder.Settings` instead.

A registry-driven loader `Application.put_env`s stored values onto a one-time bootstrap
snapshot at boot (a one-shot supervised child, after PubSub / before the poller) and on
every save. So DB overrides env, a cleared setting reverts to env, and contexts read the
same keys unchanged.

Secrets are Cloak-encrypted at rest (secret rows only; key derived from `SECRET_KEY_BASE`)
and never echoed back to the form.

The sanctioned readers are already written — expect to be editing one of them rather than
adding a new call site:

- `lib/cinder/application.ex` — the bootstrap snapshot loader and `RELEASE_NAME` check.
- `lib/cinder/settings.ex` — the env-as-bootstrap overlay.
