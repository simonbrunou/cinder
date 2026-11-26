### Added
- **Import from Prowlarr can bring a Cardigann indexer in as a native Cardigann indexer once the
  indexer definitions are loaded (#1675).** The definition is the mirror's copy of the file
  Prowlarr names, never the definition's own id. An indexer that can go direct comes ticked as a
  Cardigann indexer Cinder searches itself, pinned to that copy, unless Cinder refuses what it
  would store, as for any indexer. It takes the base URL Prowlarr searches: the one Prowlarr
  stores, matched against the definition's links with any trailing `/` cut, or the definition's
  first link when Prowlarr stores none or a legacy link. It takes Prowlarr's checkbox, text and
  password values, and for each select the option whose label is the only one with that label in
  Prowlarr and in the definition. A select Prowlarr holds another value for takes its default,
  and the row and the report say so; one Prowlarr holds no value for takes its default with no
  note, as Prowlarr does. A text or password value Prowlarr hides as `********` gets a field to
  type it again; left blank, the indexer is created disabled and the report names the setting. A
  FlareSolverr tag turns the FlareSolverr toggle on. The row says why and offers an unticked "Add
  it through Prowlarr" instead, unless Cinder refuses that too, when the definition is not in the
  mirror or was removed or replaced upstream, does not load, uses a feature Cinder does not
  support yet, or needs a newer Cinder; when the base URL Prowlarr stores is not one of its links;
  when a select would take a default it lacks; or when an HTTP, SOCKS or unknown proxy shares one
  of its tags or Prowlarr's global proxy is on. Until the definitions are first loaded, or while
  the definition's copy has not been checked yet, the row still reads "Not imported: indexer
  definitions not loaded yet". A new copy of a ticked indexer's definition, or a change in
  Prowlarr to a value the import would store, since the dialog opened shows the new list to check
  again; a copy replaced while the import saves shows on that row as a change to check again.
