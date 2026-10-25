### Fixed
- **A subtitle can be fetched for a video directly in a library root on mergerfs (#798).** When
  the library root was a folder below the mergerfs mount, fetching a subtitle for a video placed
  directly in that root failed with a write error and wrote nothing. Videos in title folders were
  not affected. Fetch the subtitle again for such a video.
