### Added
- **Import from Prowlarr in the Indexers group of Settings and of the setup wizard (#1674).**
  The button beside "Add indexer" opens a dialog that reads Prowlarr's indexers with the saved
  Prowlarr URL and API key, or asks to save them first. Each Prowlarr indexer gets a row. A
  Newznab or Torznab indexer Cinder can search itself comes ticked, with its name to edit and,
  when Prowlarr hides its API key, an API key field to type it again. One that can only be
  searched through Prowlarr, such as a C# indexer or one behind a proxy, says why and offers
  an unticked "Add it through Prowlarr". Cardigann indexers while the indexer definitions are
  not loaded yet (#1675), indexers already imported and indexers whose settings Cinder refuses,
  such as an API path that points at another host, show greyed with no tick and say why. Each
  row also names the Prowlarr settings it does not carry, such as query and grab limits. Import
  creates the ticked indexers, or none of them: two ticked rows with one name, or a name another
  indexer holds, put an error on the row, and a change to a ticked indexer in Prowlarr, or to
  the saved Prowlarr URL or key, since the dialog opened shows the new list to check again. A
  row whose hidden key is left blank is created disabled. The report lists what was created,
  created disabled and skipped as already imported. It says Cinder is testing each enabled
  indexer it created once each one's Test started, or names the ones it is testing when only
  some started, and that the indexer source stays as it was. A typed key stays in its field
  while other rows change, and the page never echoes it.
