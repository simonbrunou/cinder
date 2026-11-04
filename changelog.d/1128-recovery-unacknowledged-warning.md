### Fixed
- **Picking up an interrupted subtitle correction now logs a step it could not confirm (#1128).**
  When Cinder picks up an interrupted subtitle correction and part of putting the corrected file
  in place goes unconfirmed, it now logs the warning
  `subtitle publication unacknowledged for <subtitle file>: <cause>`, as fetching a subtitle
  already did. The warning is logged whether Cinder then records the correction or holds it for
  review.
