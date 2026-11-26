### Internal
- **`Cinder.Indexers.Definitions.apply_set/2` counts only the file names that get a mirror copy once
  the answer applies (#1731).** The 100-name floor for a first answer, the 90% line and the stored
  set's `count` take in only the names with a file in a folder from `MIN_VERSION` up to the engine's
  schema version 12. A name only in folders above 12 or below `MIN_VERSION` does not count. So take
  an answer with `MIN_VERSION` at most 12 whose names all sit above 12, at a commit other than the
  one `accept_smaller_set/1` took. When the stored set holds at least one name, the answer is now
  refused as shrunk by 100% and every stored copy, load result and entry stays. When no set is
  loaded yet, it is refused as too small with a count of 0. Before, such an answer applied when it
  held at least 90% of the stored count, or at least 100 names for a first answer, in folders from
  `MIN_VERSION` up, and the mirror then held no copy. An answer at the commit `accept_smaller_set/1`
  took still passes the guard, even when it leaves the mirror with no copy.
