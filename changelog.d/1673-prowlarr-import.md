### Internal
- **`Cinder.Indexers.ProwlarrImport` previews and commits an import of Prowlarr's indexers as
  configured indexers (#1673).** `preview/0` reads Prowlarr's
  `/api/v1/indexer`, `/api/v1/indexerproxy` and `/api/v1/config/host` with the stored Prowlarr URL
  and API key, and gives each Prowlarr indexer one row. A Cardigann indexer is held, and one an
  earlier import linked is already imported. A Newznab or Torznab indexer whose own settings fail
  the configured indexer's checks, such as a base URL with a password, additional parameters holding
  `apikey` or a priority outside 1 to 50, is refused, whatever route it would take. Any other is an
  unticked offer through Prowlarr's `/<id>/api` when its implementation is not Newznab or Torznab, a
  proxy shares one of its tags, Prowlarr's global proxy is on, or it is a Torznab indexer with
  additional parameters, refused when Prowlarr calls its protocol `unknown` or when the settings it
  would be created with fail those checks; else it is direct. `commit/3` reads Prowlarr again,
  refuses the import when the stored Prowlarr URL or key, or a ticked row's plan (its state, type,
  base URL, API path, settings, enabled state, priority, through-Prowlarr reasons or key), changed
  since the preview, and creates the ticked rows in one transaction with one audit row, each linked
  to its Prowlarr indexer by `prowlarr_indexer_id`. A direct row for which Prowlarr answers a key,
  which it masks as `********`, is created disabled with no key when the admin types none. After the
  commit, the Test runner is asked to start the Test of each enabled created indexer. The indexers
  table's Import from Prowlarr dialog runs it (#1674).
- **A content refusal under one side of an import link skips the title from the other side
  (#1673).** A series block that a client rejection, a bad torrent or a bad download file left
  under a Prowlarr indexer now also skips that title from the configured indexer linked to it,
  and the other way round.
