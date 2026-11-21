### Security
- **`phoenix_live_view` 1.2.9 → 1.2.14 (CVE-2026-126334).** A MEDIUM advisory against
  `phoenix_live_view`, which covers its 1.2 line from 1.2.0-rc.0 up to, but not including, 1.2.14.
  A signed-in user who holds a session token from a LiveView's HTTP render could join that
  LiveView over the websocket without a `"url"` or `"redirect"` key, and that join skipped the
  `on_mount` hooks of its `live_session`. The advisory says such a join fails for a LiveView that
  defines `handle_params/3`, matches its params as a map in `mount/3`, or reads an assign that a
  skipped hook sets. Cinder's router declares its sign-in, active-account and admin checks as
  `live_session` hooks. After the advisory's publication on 2026-11-20, `mix hex.audit`, which
  CI's required `dependency-audit` job runs, failed on a `mix.lock` that held 1.2.9.
