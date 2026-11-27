### Internal
- **The built-in indexer source runs the remaining Cardigann search and download keys, so 69 of the
  584 v11 definitions at Prowlarr/Indexers `56b20b19` load where 35 did (#1679).** A search sends
  `search.headers`, rendered, only to the indexer's own hosts, POST search paths with a form body,
  path `categories` (a list starting with `!` runs when none matches), `$raw` inputs encoded twice
  as Prowlarr encodes them, blank inputs under `allowEmptyInputs`, the legacy `search.path` after
  the other paths, and a path's own `followredirect`. A 301, 302 or 303 turns a POST into a GET with
  no body, a 307 or 308 keeps both, and a body that holds a secret never goes to another host. A
  page runs `preprocessingfilters` first, merges each `rows.after` group into one row, dates a row
  with no date from its `dateheaders` header, takes each `remove` match out before a field reads its
  text, on HTML and XML pages, and reads a field selector that names an earlier field's `.Result`
  value in up to three more parser worker rounds, which share the page's 30 s. On a definition that
  sets `preprocessingfilters`, an HTML or XML page longer than 64 KiB runs none and reads as
  partial. A filter or a selector template that would put a secret setting's value in the parser
  worker's input, when the site's page does not hold that value already, fails the page or the grab
  as a definition error. A grab sends `download.headers`, else `search.headers`, to the own hosts,
  sends `before` first, with the link as its `Referer` when the link is on an own host, builds a
  magnet from `infohash` with no tracker, reads the `before` answer under `usebeforeresponse`, and
  posts the final request under `download.method: post`. A `before` request whose path or inputs do
  not render, whose path is no web address or whose URL text the rules refuse, or whose answer is a
  magnet, is `{:cardigann_grab, :before_failed}`. A template limit keeps its own
  `{:cardigann_grab, kind}`, and a refusal from the address or secret check keeps that check's
  failure. An `infohash` that finds no hash is `{:cardigann_grab, :infohash_not_found}` and a header
  Cinder cannot send `{:cardigann_grab, :bad_headers}`, each a capped retry. `before.pathselector`,
  a `before.queryseparator` other than `&`, `remove` beside `case`, and `rows.after` or
  `rows.dateheaders` on a search with an XML path still read as not supported. The loader raised its
  revision to 7.
