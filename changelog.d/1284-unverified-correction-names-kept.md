### Fixed
- **A subtitle correction whose file and hidden old copy both fail to open right after it was
  written, yet Cinder reads the file back as the correction, keeps its record (#1284).** Right
  after a correction writes a subtitle file, Cinder opens the file, and the old subtitle it moved
  into the hidden `.cinder-subtitle-sync-cas-*` folder beside it, to check that each is still the
  file Cinder put there. When both opens failed, the correction dropped its record although the
  file held the corrected subtitle, and the next manual correction of that subtitle failed as
  changed outside Cinder. Cinder now reads the file back when both opens fail too. When the read
  works and the file holds the corrected subtitle, the correction keeps its record. It then leaves
  the old subtitle in the hidden folder as it is, also for a subtitle that is a hardlink to a
  download's file. The recovery that records the correction tries to empty that old subtitle, or
  to drop the folder's name for the download's file, as the entry for #1149 says.
