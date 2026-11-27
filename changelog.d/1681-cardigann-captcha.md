### Added
- **A Cardigann site whose login form shows an image captcha can now be added, and you solve
  its captcha in the indexer's Edit dialog (#1681).** In `/settings`, the Edit dialog of such an
  indexer has a Captcha section. Show captcha loads the site's login page and its captcha image;
  type the answer and save. The save then starts the indexer's Test, enabled or not, which posts
  the login form of that page with your answer and keeps the login's cookies as any other login
  does. The save is refused, and asks for a new captcha, when the captcha was shown more than 5
  minutes ago or when the same save changes the base URL. While another Test of the indexer runs,
  the dialog stays open and asks you to save again once it ends. An answer the site refuses reads
  "Login rejected". The Add form of such a site says to save it first; once saved, it opens as
  the new indexer's Edit and loads the captcha. The image shows only when the site sends a PNG,
  JPEG, GIF or WebP file of at most 1 MiB, and the answer is filtered from the logs.
- **A search, Test or grab that has to log in to such a site, and finds the captcha on its login
  page, stops before it sends the form (#1681).** An enabled indexer's state then reads "Login
  needs a captcha: solve it in Settings". As after a refused login, the indexer then gets no
  search request; a Test that passes ends that, and so does a save of a new base URL or new
  credentials, while a save of only its name, priority or Enabled keeps it. A grab that meets
  the captcha fails as a grab under a refused login does. A login page that shows no captcha
  logs in as before. The loader loads an image captcha on a `form` login and raised its
  revision to 11.

### Internal
- **`Native.load_captcha/1` and the `native_indexer_captchas` table (#1681).** The load runs in
  a process of its own under the heap cap and keeps the login page's cookies and form in one
  encrypted row per indexer, which lives 5 minutes, is used once, and is read only under the
  base URL and definition copy it was loaded with. `Native.test_indexer/2` and
  `TestRunner.start/2` take the answer as a `captcha` option.
