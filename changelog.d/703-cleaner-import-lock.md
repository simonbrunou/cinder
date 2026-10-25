### Fixed
- **The download cleanup no longer removes a Usenet download an import is still finishing
  (#703).** An import that started more than an hour after its download completed, such as one
  held until the library paths were configured, could lose the release's subtitle files when the
  hourly cleanup removed the download in the seconds before they were linked. The cleanup now
  waits for a running import to finish before it checks whether anything still owns a download
  and removes it.
