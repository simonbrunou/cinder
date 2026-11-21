### Internal
- `Cinder.Library.BoundedWalk.run/3` takes a `:call_timeout_ms` option, the timeout of each call
  that it and its walk's task make to the walk guard (#1512). Left out, it is 5 s, as before. No
  caller in the app passes it, so directory walks behave as before. `BoundedWalkTest` passes 20 s,
  or 100 ms in two tests of the option itself.
