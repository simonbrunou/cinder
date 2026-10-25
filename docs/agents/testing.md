# Testing

- `mix test` decides when a task is done. Before you start, write the done-when as something
  `mix test` can check, then loop until it is green.
- A bug fix starts with a test that reproduces the bug. Then make it pass.
- New functionality, such as a choke-point, a state or a writer, ships with a test.
- Tests never hit the network or a real service. `config/test.exs` points each external-service
  behaviour at its Mox mock, so a test that needs service behaviour sets an expectation on the
  mock. The behaviour list is in [architecture.md](architecture.md).
- A new UI string fails `translations_complete_test` until you run
  `MIX_ENV=test mix gettext.extract --merge` and write its French msgstr in
  `priv/gettext/fr/LC_MESSAGES/default.po`. When an existing msgid is close enough, the merge
  fills the new one with that translation and flags it `#, fuzzy`. Remove the flag and rewrite
  that msgstr by hand, especially when the new msgid contains an old one: "Jellyfin web URL"
  was filled with "URL Jellyfin", the translation of "Jellyfin URL".
- A test sets a `:cinder` env key with `Cinder.ConfigCase.put_env/2`, which restores the old value
  on exit. For a keyword-list key, `Cinder.ConfigCase.put_config/2` merges the overrides and
  restores the same way. The household size band (`:tv_min_size`, `:tv_max_size`, read by
  `Cinder.Acquisition.HouseholdPolicy.band/1`) is one such key. When other test modules also read
  the key, as several read the band, set it from an `async: false` module.
