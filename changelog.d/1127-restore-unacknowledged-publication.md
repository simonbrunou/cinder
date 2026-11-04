### Fixed
- **Putting a subtitle's original back no longer fails when part of it goes unconfirmed
  (#1127).** When a reset, or the cleanup after a corrected subtitle's video changed, put the
  original subtitle in place but Cinder could not confirm the swap or a step after it, such as a
  file that failed to close, Cinder treated the restore as failed although the subtitle file held
  the original. For example, the subtitle sync page said "Original subtitle could not be
  restored.", or an analysis held the track for review. It now goes on as it would with every
  step confirmed, and logs a warning that names the subtitle file.
