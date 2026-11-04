### Internal
- The test-only `:health_probe_timeout_ms` key, the timeout budget of the health checks on
  `/settings`, `/setup` and `/dashboard`, also takes a map from probe id to budget (#1123). A
  test now shrinks only the budget of the probe meant to time out, so a slow CI runner no longer
  fails the healthy probes beside it. The checks behave as before.
