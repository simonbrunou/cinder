---
description: External services are reachable only through behaviours resolved at runtime; tests never touch the network.
globs:
  - lib/cinder/catalog/**
  - lib/cinder/acquisition/**
  - lib/cinder/download/**
  - lib/cinder/library/**
  - test/**
---

Every external service sits behind a behaviour, resolved with `Application.fetch_env!/2`, and
tests use its Mox mock. Before calling a service or writing a test against one, read "External
services go through behaviours" in `docs/agents/architecture.md` for the behaviour list and the
reason, and `docs/agents/testing.md` for the mock rules.
