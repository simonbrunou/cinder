### Internal
- **A store for configured indexers, which nothing reads yet (#1649).** A migration adds the
  `configured_indexers` table, and `Cinder.Indexers` is its one writer: it creates, edits,
  turns on or off and deletes Newznab and Torznab rows, each with an optional API key that it
  stores encrypted, and refuses Cardigann rows. No page, search or import calls it yet, so
  Cinder searches through Prowlarr as before. `Cinder.Settings.Crypto` now decrypts the secret
  settings through `Cinder.SecretCodec.decode/1`, which reads a value encrypted under another
  `SECRET_KEY_BASE` as unreadable, as `Crypto` did before.
