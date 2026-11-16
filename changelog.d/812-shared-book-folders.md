### Internal
- **The book folders live in `Cinder.Library.BookFolders` (#812).** E-book and audiobook imports
  both take their `Author/Title` folder names from it, so the audiobook naming no longer calls
  the e-book module. Books land in the same folders as before.
