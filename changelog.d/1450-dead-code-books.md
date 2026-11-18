### Internal
- **Three uncalled functions and two unused book schema fields are gone, and the book judge reads
  a requested language through `Cinder.Acquisition.Language.lookup/1` (#1450).**
  `AnimePreferences.release_allowed?/2`, `Download.Intent.valid_parser_snapshot?/1` and
  `Library.AudiobookSources.safe_source/1`, which nothing called, are gone. The
  `Cinder.Books.Author` and `Cinder.Books.Work` schemas no longer list `sort_name` and
  `original_title`, which no code set or read. Their database columns stay. `BookScorer` now maps
  a requested language to its release tag through `Language.lookup/1`, which pins the generic
  Chinese codes `chi` and `zho` to Chinese, instead of its own walk over the parser's language
  table. Which releases a book request accepts is unchanged.
