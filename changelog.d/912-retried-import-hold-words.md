### Changed
- **A book held after its import retries ran out says why in a sentence on its page and in the
  Discord and email notifications, when Cinder recognizes the error (#912).** These now explain
  errors such as a file that is not in the format its name claims, a folder where the book's file
  goes, an unset library or download folder, a permission error or a full disk in words, instead
  of a code like `format_mismatch` or `{:unexpected_destination_type, :directory}`. Errors Cinder
  does not recognize still show as before, and the generic webhook still sends the code.
