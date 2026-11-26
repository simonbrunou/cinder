### Security
- **A refused base URL, API path or additional parameters value is no longer shown again in the
  indexer dialogs (#1697).** Such a value can carry a credential, such as
  `https://user:KEY@indexer.example` or `&apikey=KEY`. After a save that refuses one of these
  three fields, in the Add or the Edit dialog of `/settings`, that field is empty, with its reason
  under it, even while the cursor is still in it. The other values you typed stay. A refusal of
  another field, such as the priority, empties none of them.
- **Request and LiveView event logs print `[FILTERED]` for a parameter whose name contains
  `base_url`, `api_path` or `additional_parameters` (#1697).** The indexer dialogs send their base
  URL, API path and additional parameters under those names, so those logs no longer print what
  you typed there.

### Internal
- **`Cinder.Indexers` returns a refused base URL, API path or settings value nowhere in its
  changeset (#1697).** `ConfiguredIndexer.drop_refused/1` takes the typed value of each of these
  fields that carries an error out of the changeset's changes and leaves its param as `""`,
  whichever rule refused it, on a create and on an edit, the stale-save and secrets refusals
  included, and on a Cardigann copy's refusal of the settings or of the base URL's links.
