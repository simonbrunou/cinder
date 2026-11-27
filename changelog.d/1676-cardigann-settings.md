### Added
- **Add indexer can add a Cardigann site once the indexer definitions are loaded (#1676).**
  In the Indexers group of `/settings` and of the setup wizard, Add indexer lists each site of
  the loaded definitions after Newznab and Torznab, with its privacy, language and description,
  and a search box filters the sites by name and description. A site whose definition Cinder
  cannot run yet shows greyed with the reason and opens no form. Until the definitions are first
  loaded, the list says so and still offers Newznab and Torznab. A site's form holds its name,
  a select of the site's addresses, a field or a notice for each setting its definition declares
  apart from the FlareSolverr notice, a notice with no text to show, and the setting types Cinder
  does not know, then priority and Enabled. For a site whose `form` login shows an image captcha,
  Edit shows the captcha section of #1681 before priority, and Add a line saying to save the
  indexer first. A site that signs in with a cookie also shows how to copy the cookie from the
  browser. Cinder stores a text or password value encrypted and never shows it again, and a
  checkbox or select value plain. Edit opens the same form on the copy the indexer runs, or only
  the name, priority and Enabled when Cinder can no longer read that copy. A save is
  refused when the site's definition changed while the form was open.
- **The indexer definitions line under the indexers table (#1676).** It reads "Indexer definitions:
  N loaded at <commit>, checked <time>" with Update now, which starts the definitions job, or
  joins the run in progress, and shows how it ended. It adds a badge once every run since the
  last success has failed and that success is over 72 hours old, an alert with Accept smaller
  set when Cinder refused an upstream answer as too small, and a red alert when the definitions
  need a newer Cinder. Before any set is loaded, it reads "Indexer definitions not loaded yet"
  with the last fetch error and Retry.
- **Accept update for a Cardigann indexer (#1676).** A row whose definition update waits for you
  shows Accept update. Its confirm lists the hosts the new copy names that the running one does
  not, and applies the copy it showed, or says the copy changed before the click.

### Changed
- **The indexers table words each Cardigann definition state (#1676).** A Cardigann row now
  shows the detail of its definition state under its badge, such as "Running copy no longer
  loads on this build", and each Cardigann search failure has its own words where it read
  "Failed". Test is disabled for an indexer whose running copy no longer loads or uses a feature
  Cinder does not support yet. Import from Prowlarr's not-supported reasons now read as words,
  such as "Not supported: the oneurl login" where it read "Not supported: login oneurl". `/activity`
  lists the definitions job as "Update indexer definitions".
- **On the first start after this update, Cinder checks each stored indexer definition again
  (#1676).** Its definition reader now stores each site's name. Until a copy's check ends, a
  Cardigann indexer on that copy gets no search request, and a grab of its release is retried
  later.
