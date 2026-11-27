### Internal
- **The built-in indexer source reads a Cardigann definition's JSON and XML search answers, and
  runs its legacy encodings and pinned certificates (#1678).** A search path whose
  `response.type` is `json` reads its rows as Prowlarr's `CardigannParser` does: its
  `noResultsMessage`, `rows.count`, the rows selector with its `:has`, `:not` and `:contains`
  filters, `rows.attribute`, `rows.multiple`, and each field's path, an array's items joined with
  `,`. A body that holds a `noResultsMessage` that is not blank gives no rows, and so does a
  blank body when the message is blank. Otherwise a body that is not JSON fails the indexer, and
  so does one that nests more than 64 objects and arrays, which Newtonsoft's reader refuses. A
  `rows.count` that reads below 1 then gives no rows, and a body with no rows list fails the
  indexer unless `rows.missingAttributeEqualsNoResults` is set. The per-indexer Test now parses
  its answer under the search processes' heap cap. A path whose type is `xml` reads its rows
  with Floki once each selector passes a strict check, and a body that holds a DTD or an entity
  declaration fails the indexer with nothing in it expanded. The `jsonjoinarray` filter runs. A
  definition whose `encoding` is one of the nine charsets of #1677 reads its search, Test and
  grab pages in that charset whatever their `Content-Type` says, and writes its query inputs and
  its `urlencode` and `urldecode` filters in it. A server certificate whose SHA-1 the
  definition's `certificates` lists is accepted on the base URL's host though no trusted root
  signed it, and every other host verifies as before. The definition loader no longer reports
  these as not supported and raised its revision to 6. `LoadCheck` adds `{:json, :path}`,
  `{:xml_selector, name}`, `{:xml_selector, :invalid}` and `{:certificates, :malformed}`, and
  `IndexerStateText` names the four new failures in English and French.
