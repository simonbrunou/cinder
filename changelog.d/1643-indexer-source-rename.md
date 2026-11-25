### Internal
- **The indexer seam is now `Cinder.Acquisition.IndexerSource` (#1643).** The behaviour
  `Cinder.Acquisition.Indexer` is renamed `Cinder.Acquisition.IndexerSource`, its Prowlarr
  adapter `Cinder.Acquisition.IndexerSource.Prowlarr`, and the app env key that names the adapter
  `:indexer_source`. When `PROWLARR_URL` is set, `config/runtime.exs` now writes it and
  `PROWLARR_API_KEY` under `Cinder.Acquisition.IndexerSource.Prowlarr`. The saved `prowlarr_url`
  and `prowlarr_api_key` settings keep their keys, and their `Cinder.Settings.Registry` targets
  now name `Cinder.Acquisition.IndexerSource.Prowlarr`, so no stored setting changes.
