### Changed
- **The `/library/adopt` note on works Readarr monitored without a file names eBooks and
  audiobooks (#813).** It now says to monitor their eBooks per author or request their audiobooks
  after cutover, since an author policy monitors only eBooks. The migration runbook and the
  operating guide say the same.

### Internal
- **The author monitoring policy is `Cinder.Books.EbookAuthorPolicy` (#813).** It arms e-book
  targets only, as before, and its moduledoc says why. The `book_author_policies` table keeps its
  name, so stored policies need no migration.
