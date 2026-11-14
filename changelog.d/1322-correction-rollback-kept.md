### Fixed
- **A subtitle correction whose hidden old subtitle fails to open right after it was written, and
  whose undo then fails without finding another file in the old subtitle's place, keeps its record
  when Cinder reads the file back as the correction (#1322).** Right after a correction writes a
  subtitle file, Cinder opens the file, and the old subtitle it moved into the hidden
  `.cinder-subtitle-sync-cas-*` folder beside it, to check that each is still the file Cinder put
  there. When the file passed and the old subtitle's open failed, Cinder tried to put the old
  subtitle back. When that undo failed before the old subtitle was back, for example because the
  old subtitle failed to open again, a manual or automatic correction dropped its record, leaving
  the subtitle with the record it had before, if any. When the file held the corrected subtitle,
  the next manual correction of that subtitle then failed as changed outside Cinder. Cinder now
  reads the file back when the undo fails, unless the undo found another file where the old
  subtitle was. When the read works and the file holds the corrected subtitle, the correction
  keeps its record. It then leaves the old subtitle in the hidden folder as it is, also for a
  subtitle that is a hardlink to a download's file. The recovery that records the correction
  tries to empty that old subtitle, or to drop the folder's name for the download's file, as the
  entry for #1149 says.
