### Fixed
- **Subtitle reads run at low CPU and disk priority (#862).** Listing a video's subtitle tracks,
  extracting one and finding its shot changes read the whole file. They now run at nice 10 and
  at the idle disk I/O class, so playback and imports on the same disk read first during a
  subtitle sweep. The I/O class takes effect only under a disk scheduler that honours it (BFQ,
  or mq-deadline from Linux 5.14), and not when the library sits behind a FUSE mount such as
  mergerfs without passthrough, whose own process does the reads. A host without `ionice` or
  `nice` on `PATH` runs the reads without that tool.
