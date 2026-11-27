### Internal
- **The built-in indexer source can search, Test and grab a Cardigann indexer
  whose definition signs in with a `post`, `get`, `form` or `cookie` login (#1680).**
  `Cinder.Acquisition.Indexer.Cardigann.Login` runs the definition's `login` block as Prowlarr
  does: it posts or gets the login inputs, fills and submits the site's login form, with
  its hidden inputs, `selectorinputs`, `getselectorinputs` and a simpleCaptcha, or uses the
  cookie the admin saved. A saved cookie and `login.cookies` go to every one of the indexer's
  own hosts. `Cardigann.Session` keeps the login's cookies in the new `native_indexer_cookies`
  table, one encrypted row per indexer, used for 30 days. A row saved under the indexer's earlier
  credentials is never used, and the next read of it tries to delete it. A cookie a search,
  login or grab answer from the indexer's own hosts sets updates the row. A search or Test logs
  in only when no row reads or an answer shows a login sign: a redirect it does not follow, a
  401, or a page the `login.test.selector` does not match. Then it logs in once and sends the
  request once more, and a second sign is rejected credentials. A `cookie` login has nothing
  to log in with, so its first sign is rejected credentials. A refused login is recorded as
  `{:login_rejected, method}`, and the indexer state reads "Login rejected: check the username
  and password in Settings", or "Cookie rejected: paste a new one in Settings" for the `cookie`
  method. A grab logs in the same way when a details page answers a login redirect, a 401
  or a login page. A grab under a refused login sends nothing, and a grab whose login fails
  otherwise records that failure, or the indexer's limit, as a search does. The login inputs,
  the cookies and the login headers go only to the indexer's own hosts, and no login request
  is retried. The loader loads these logins and the `info_cookie` setting type, and raised its
  revision to 8. A `oneurl` login still reads as not supported, and so does a login with a
  `captcha` block, except an image captcha on a `form` login: when the login page shows it,
  #1681 stops the login before it sends the form and lets you solve the captcha in Settings.
