### Fixed
- **A fetched subtitle no longer stays hidden on a mergerfs branch after losing a race (#796).**
  When another program created the same subtitle name on a different mergerfs branch while
  Cinder was fetching it, Cinder's copy stayed under that name on its own branch, hidden or
  hiding the other file, and the fetch was sometimes recorded as Cinder's. Cinder now takes its
  copy back, leaves the other file alone and records nothing, as for any fetch that finds the
  subtitle already there. A copy an earlier fetch left behind stays on its branch: if
  `getfattr -n user.mergerfs.allpaths <subtitle>` lists two paths, delete the one you don't
  want from its branch.
