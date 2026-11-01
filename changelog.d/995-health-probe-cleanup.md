### Fixed
- **A failing library health check no longer leaves a probe file in the library root (#995).**
  The library check on `/dashboard`, `/settings` and the setup page creates a hidden
  `.cinder-health-probe-<N>` file to prove the root is writable. When the create succeeded but a
  later write, fsync or mergerfs step failed, the check reported the error and kept the empty
  file, so each failing check added another. The check now removes it and still reports the
  error. Probe files left by earlier versions stay: delete any `.cinder-health-probe-*` file in
  a library root by hand.
