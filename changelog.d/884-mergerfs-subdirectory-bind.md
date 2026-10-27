### Fixed
- **A subtitle correction that meets a duplicate backup through a `/media` bind of a mergerfs pool
  folder now fails with a reason that names that layout (#884).** Cinder clears an empty subtitle
  backup that a past correction left on two mergerfs branches by reading the pool's branch list,
  which mergerfs keeps at the pool root. When `/media` binds a folder inside the pool instead,
  Cinder now refuses before it reads that list or touches a backup. The correction fails with
  `mergerfs_subdirectory_bind` and the folder's path inside the pool (for example `/media`)
  instead of a bare `enoent`. Bind the pool root at `/media`, as `docs/operating.md` now says.
