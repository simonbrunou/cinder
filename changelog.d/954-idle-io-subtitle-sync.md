### Fixed
- **Subtitle sync runs at low CPU and disk priority (#954).** Aligning a subtitle against a
  video's audio reads and decodes the whole file. Every subtitle sync now runs at nice 10 and at
  the idle disk I/O class, as the subtitle reads do since #862, so playback and imports on the
  same disk read first during a sync sweep. The I/O class takes effect only under a disk
  scheduler that honours it (BFQ, or mq-deadline from Linux 5.14), and not when the library sits
  behind a FUSE mount such as mergerfs without passthrough, whose own process does the reads. A
  host without `ionice` or `nice` on `PATH` runs the sync without that tool.
