### Internal
- **A parity report's row difference now prints how many rows of that indexer in that call each
  side has left to compare, and lists at most 10 one-sided entries per side (#1916).**
  `Cinder.Indexers.Parity.Text` prints the count before the list, for example
  `Prowlarr 3 rows, Native 0 rows`, so a side with no row left to compare reads apart from a
  short one. It counts the rows the check compares: after the timing cut, with Native's copies of
  one link that Prowlarr merged counted once. Each entry of a side's list is one title at one
  size with its row count. The list is sorted by title and size, and past 10 entries it ends
  with how many more entries there are and how many one-sided rows in all, as in
  `and 30 more entries (41 rows in all)`. Before, the line listed every one-sided row, so a line
  of #1690's second parity run on prod held over 8,800 characters.
