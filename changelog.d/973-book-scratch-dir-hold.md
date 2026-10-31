### Fixed
- **A book whose leftover extraction folder cannot be removed now holds (#973).** When the
  `.cinder-extract` folder beside a zipped or RAR e-book or audiobook could not be removed (a
  permission or busy-mount error), the import failed the same way on every poll and the book
  retried forever. It now takes the usual import retries, then holds with the filesystem error
  shown, so you can fix the folder's permissions or remove it and retry.
