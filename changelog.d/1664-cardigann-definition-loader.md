### Internal
- **`Cinder.Indexers.Definitions.Loader.load/1` reads one Cardigann definition file (#1664).**
  It answers that the file fails to load, with a reason, or returns the parsed definition with
  the list of engine features the file uses that Cinder has not built. Every feature is off for
  now, so each upstream file with a search path reads as not supported. Nothing calls the loader
  yet. The release image now ships `yaml_elixir` and `yamerl`, which it reads YAML with.
