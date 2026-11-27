### Added
- **A Cardigann indexer can get past a Cloudflare or DDoS-Guard challenge through FlareSolverr
  (#1682).** A Cardigann indexer's form has a "Use FlareSolverr" toggle, off for a new indexer. With
  the toggle on and a FlareSolverr URL saved, when the site answers a search, a Test, a login
  request or a grab with a challenge page, Cinder asks FlareSolverr to solve it, then sends the
  request once more with the cookies and user agent FlareSolverr returns. A request that carries a
  secret, such as a login, never goes to FlareSolverr: Cinder asks it to open the indexer's base URL
  instead. Cinder keeps the returned cookies that belong to the site's own hosts, encrypted, for 30
  days, and sends them with the indexer's later requests to those hosts until the indexer's base
  URL, settings, toggle or secrets change. A challenged request, its solve and its second send share
  one deadline of at most 60 seconds. A challenge Cinder does not get past fails the request, with
  "Cloudflare challenge" when the toggle is off, the challenged page is not on the site's own hosts,
  or the second send meets a challenge again, "FlareSolverr URL not set" while no URL is saved,
  "FlareSolverr answered from another site" when the page FlareSolverr's browser ended on is not on
  the site's own hosts, and "FlareSolverr failed" when FlareSolverr's answer holds no solution
  Cinder can use.
- **The FlareSolverr line under the indexers table (#1682).** It reads "FlareSolverr: <URL>" or
  "FlareSolverr: not set", and Set or Edit opens a dialog that saves the URL, an http or https URL
  with no user name, query or fragment. A blank save clears it. While enabled Cardigann indexers
  have the toggle on, the dialog first says how many, and a second blank save clears it. The
  Cardigann form shows a FlareSolverr URL field while the toggle is on and no URL is saved, and
  saves that URL before the indexer, so the URL stays saved when the indexer's save is refused.
- **Import from Prowlarr offers Prowlarr's FlareSolverr address (#1682).** While Cinder has no
  FlareSolverr URL saved and every FlareSolverr proxy in Prowlarr uses one host that Cinder accepts
  as a URL, the preview reads "Prowlarr uses FlareSolverr at <host>" with an unticked "Save it as
  Cinder's FlareSolverr URL". Ticked, the import saves that host before it creates the indexers,
  unless a URL was saved since the preview, and its report says so. Unticked, the report lists
  "FlareSolverr URL not set" under each indexer it created with the toggle on.
