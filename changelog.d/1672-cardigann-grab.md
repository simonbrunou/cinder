### Internal
- **The built-in indexer source can grab a Cardigann indexer's release, and a Torrent9-shaped
  definition, whose download block reads the magnet off the release's details page,
  now loads (#1672).** `Native.fetch_download/3` hands a Cardigann indexer's link to
  `Cinder.Acquisition.Indexer.Cardigann.Grab`, which reads the indexer's running definition
  copy first: a copy the current loader has not checked yet is a capped retry, and any other
  copy that no longer loads drops the grab as `:indexer_changed`, both with no request. With no
  `download` block it fetches the link. With one that lists `selectors`, it fetches the details
  page once, reads every selector in one parser worker, and takes the first value its filters
  leave that is not blank: a magnet goes back to the client, which a Usenet client refuses,
  and any other value is resolved against the page's address and fetched when it is a web
  address, else skipped. A link Cinder's URL rules refuse, such as one holding a user name,
  is skipped too. With `testlinktorrent` on, Prowlarr's default, a link that answers 2xx with
  a body that is not empty, does not start with `d` once inflated, and is no login page of the
  indexer, moves on to the next selector. Every answer goes through the shared download check,
  which records the indexer's limit, rejected credentials or failure in Native's backoff state as
  for a Newznab grab, but for the login rules #1680 adds. One 90 s deadline covers the
  whole grab, and the parser worker is killed at it. Each request goes only to a public
  address, follows at most five redirects, is never retried and adds no `Referer` of its own,
  but for #1679's `before` request and #1680's form login. A request that would carry a secret
  setting to a host outside the indexer's own hosts is never sent, and a magnet that would
  carry one is refused. A URL or magnet carries one when it holds a secret value, or when the
  definition's row fields or download block name a secret setting that holds one. A cookie one
  of the indexer's own hosts sets on a request of the download block goes back only to that
  scheme, host and port, and only for the rest of the grab, but for #1680's stored login
  cookies. A failure of the download block, such as no link, a parser worker crash, a regex
  limit, the deadline or a refused secret host, is a capped retry (`{:cardigann_grab, tag}`). The
  definition loader runs a download block's `selectors` and `testlinktorrent`, and raised its
  revision to 5.
- `mix cinder.definitions.canary` now queries the Torrent9 definition instead of listing it as not
  supported.
