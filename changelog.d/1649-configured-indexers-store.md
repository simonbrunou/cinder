### Internal
- **A store for configured indexers, which no page offers yet (#1649).** A migration adds the
  `configured_indexers` table, and `Cinder.Indexers` is its one writer: it creates, edits,
  turns on or off and deletes Newznab and Torznab rows, each with an optional API key that it
  stores encrypted (Cardigann rows came with #1668). No page calls it. The native indexer source
  reads it (#1651), and so does the check before a native grab's fetch (#1656).
  `Cinder.Settings.Crypto` now decrypts the secret settings through
  `Cinder.SecretCodec.decode/1`, which reads a value encrypted under another `SECRET_KEY_BASE` as
  unreadable, as `Crypto` did before.
