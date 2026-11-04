### Fixed
- **The leftover download folders page no longer scans forever when a download folder's file
  listing stops answering (#1113).** When a download folder's listing does not answer within
  30 seconds, the scan now ends with "The download folder … could not be read." instead of a
  spinner that never stops. A job folder whose file listing does not answer within 5 minutes is
  listed as held and Unreadable, and clearing it skips it and deletes nothing. The delete itself
  still has no time limit. After either timeout, each later scan that reaches that download
  folder ends there at once with "could not be read" until the late listing finishes.
