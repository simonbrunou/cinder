### Fixed
- **A failed poster no longer shows a broken-image icon after a live update (#702).** When a live
  update re-rendered a card whose poster had failed to load, such as a status or download
  progress change on the library, the browser's broken-image icon and the title as alt text
  came back in place of the placeholder. The placeholder now stays. A poster whose image a live
  update changes is checked again: the new image shows when it loads and is hidden when it
  fails.
