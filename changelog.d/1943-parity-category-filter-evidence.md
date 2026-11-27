### Internal
- **A parity try that differs only by Built-in rows outside the searched categories now gives
  evidence to each covered indexer that keeps rows on both sides, unless such a row changed a
  pick or the try is inconclusive (#1943).** `Cinder.Indexers.Parity.compare/1` gives evidence
  from a try that a known difference explains in one case: the `:category_filter` difference
  alone explains it, every gap it recorded is a row gap, and the try has no inconclusive reason,
  as recorded or once that filter applies. An indexer then gets evidence when it is covered and
  holds rows on both sides once that filter drops Built-in's rows outside the searched
  categories. A try that another known difference explains too, or where such a row changed a
  pick, still gives none. Before, no try that a known difference explained gave evidence. In the
  second parity run of #1687, Nyaa.si's only gap in its anime search was 13 Built-in rows
  outside the searched categories, such as soundtracks and artbooks, and the run printed
  `Nyaa.si (#4) has no search where both sides returned matching rows`.
