### Added
- **Held books show on the Activity page and count as needing attention (#773).** A held e-book
  or audiobook now has a row in a "Held books" section of `/activity`, with its hold reason in the
  words its book page uses, a link to that page and a Retry button. A Clear blocklist button shows
  while the book has a blocked release. The Activity badge in the navigation and the pipeline pill
  count each held book, and a notice appears when a book is held. A book leaves the list
  and the counts once it is no longer held.

### Fixed
- **A book's page open as the book is held over a failed release shows its Clear blocklist
  button (#773).** Cinder now records the failed release before it announces the hold, so the
  page finds it. Before, the page could miss it and hide the button until it next re-read the
  book.
