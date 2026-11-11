### Fixed
- **A recovery that records a subtitle correction whose rename failed now tries to drop the hidden
  link to a download's file that the rename left (#1156).** A subtitle that came with a release
  may be a hardlink to the file in its download folder. One step of correcting such a subtitle's
  timing renames an empty file over the hidden `.cinder-subtitle-sync-cas-*` folder's name for the
  download's file. When that rename failed, the folder beside the subtitle kept that second name,
  so deleting the download no longer freed the file. Cinder now leaves that folder as a correction
  stopped just before the rename leaves it, with the empty file beside that name, and tries to
  remove it as the entry for #1131 says, under the same conditions. A recovery that records the
  correction tries to drop that name and remove the folder, also when the download's file was
  deleted first. When the correction stopped instead, because right after writing the subtitle
  Cinder found it replaced or could not open it, and then did not read the corrected subtitle back
  from it, Cinder tries when it analyzes the subtitles of that video, under the conditions the
  entry for #1131 gives for an analysis.
