# Season Disclosures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start every TV season collapsed on the series detail page.

**Architecture:** Wrap each existing season block in native `<details>`/`<summary>` markup. The
browser owns the open state; the page sends no event and persists no preference.

**Tech Stack:** Phoenix LiveView HEEx, ExUnit, native HTML disclosures.

## Global Constraints

- Every season, including specials, starts collapsed.
- Keep existing season and episode controls inside the disclosure body.
- Do not add JavaScript, LiveView state, dependencies, or configuration.

---

### Task 1: Render closed season disclosures

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Modify: `test/cinder_web/live/series_detail_live_test.exs`
- Modify: `priv/gettext/default.pot`
- Modify: `priv/gettext/en/LC_MESSAGES/default.po`
- Modify: `priv/gettext/fr/LC_MESSAGES/default.po`

- [ ] Add a LiveView test that creates a series, asserts `details > summary` contains its season
  name, and refutes `details[open]`.
- [ ] Run `mix test test/cinder_web/live/series_detail_live_test.exs:106`; it must fail before
  the template has disclosure markup.
- [ ] Replace the season `<section>` wrapper with `<details>` and the season title with a
  `<summary>`, without an `open` attribute. Keep the existing buttons and episode list after the
  summary.
- [ ] Run `mix format lib/cinder_web/live/series_detail_live.ex test/cinder_web/live/series_detail_live_test.exs`.
- [ ] Run `mix gettext.extract --merge` to refresh generated source references after moving the
  existing gettext calls.
- [ ] Run `mix test` and require exit code 0.
