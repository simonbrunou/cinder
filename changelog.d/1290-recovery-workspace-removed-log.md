### Fixed
- **A recovery that logs a subtitle correction's hidden folder as kept, then removes that folder,
  now logs the removal too (#1290).** When Cinder records an interrupted subtitle correction, also
  in the recovery a reset runs first, it first tries to empty the old subtitle left in the hidden
  `.cinder-subtitle-sync-cas-*` folder beside the subtitle, or to drop that folder's name for a
  download's file. When that step failed, Cinder logged `subtitle workspace kept at <folder>`, yet
  the folder removal that follows the recorded correction could still remove the folder, and no
  line said so. Now that removal logs a `subtitle workspace removed at <folder>` warning after the
  kept one. When the folder stays, Cinder logs what it logged before.
