### Fixed
- **Finishing an interrupted subtitle correction no longer fails when the file swap goes
  unconfirmed (#872).** When Cinder finished a subtitle correction that had been interrupted and
  could not confirm part of putting the corrected file in place, such as a file that failed to
  close, it treated the correction as failed although the subtitle file held the corrected
  bytes. It now records the correction as aligned whenever it would have with that part
  confirmed.
