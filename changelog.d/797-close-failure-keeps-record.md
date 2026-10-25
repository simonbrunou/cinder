### Fixed
- **A subtitle correction is no longer undone by a file that fails to close (#797).** When a
  file handle failed to close after the corrected bytes were already in place, Cinder put the
  previous sync record back over them, and the sidecar then waited for review as externally
  modified. The correction now keeps its pending record, and the next subtitle sync of that
  video records it as aligned.
