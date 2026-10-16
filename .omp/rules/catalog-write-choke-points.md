---
description: Status and derived-state writes must go through the Catalog choke-points; these caller modules hold no Repo mutations of their own.
globs:
  - lib/cinder/download/**
  - lib/cinder/library/**
  - lib/cinder/acquisition.ex
  - lib/cinder/acquisition/**
condition: 'Repo\.(insert|insert!|update|update!|delete|delete!|insert_all|update_all|delete_all)'
---

You are adding a `Repo` mutation to a module that is supposed to have none.

Before you continue, read "Status writes go through the choke-points" in
`docs/agents/architecture.md`. It names the choke-points and the sanctioned exceptions, each
owning its own table. If your write is not one of those exceptions, move it behind a Catalog
choke-point instead.
