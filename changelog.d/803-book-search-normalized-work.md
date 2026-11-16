### Internal
- **The book search's normalized work is a struct (#803).** `Cinder.Acquisition.BookSearch` now
  builds a `BookSearch.NormalizedWork` and returns one unchanged when asked to normalize it again,
  so a caller that passes it back to `search/2` keeps the ISBN probes of an e-book search. Book
  searches send the same queries and judge releases as before.
