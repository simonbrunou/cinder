### Changed
- **A held book says why in a sentence (#816).** The book page, the refused-grab message and the
  Discord and email notifications for a held e-book or audiobook now explain the hold in words,
  such as "The download client no longer has this download.", instead of a code like
  `download_not_found`. The email uses the requester's language; Discord stays in English. A
  client's own message still follows the sentence. Older holds with text Cinder does not
  recognize show it as before, and the generic webhook still sends the code.
