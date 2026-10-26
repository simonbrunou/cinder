### Fixed
- **A download folder on a hung network or FUSE mount no longer freezes Cinder (#779).** Reading
  such a folder used to block the importers until the mount answered, and with them every other
  file read in the app, the web pages included. The importers' folder scan now gives up after
  30 seconds, and the import waits for the mount without counting the wait as a failed attempt,
  so a download is never given up on because its folder scan timed out. While a scan stays
  stuck, new scans of that download folder fail at once instead of piling up, and they work
  again once the mount answers.
