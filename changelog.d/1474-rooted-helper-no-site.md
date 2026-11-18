### Internal
- **The rooted filesystem helper starts without Python's `site` import (#1474).** Cinder starts a
  new `python3` helper process for most guarded file operations under a library root, and two to
  write or create a file there. It now starts each one with `-S`, which skips the `site` import
  the helper never used: each start took about 10% less time on the release image's Python.
