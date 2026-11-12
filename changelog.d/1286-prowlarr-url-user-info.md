### Fixed
- **A Prowlarr URL with user info, such as `http://user:pw@prowlarr:9696`, no longer stops the
  download links on that URL's own scheme, host and port in releases found after this update
  (#1286).** Cinder records the address it trusts for such a link without the user info now, so
  each download client fetches it as it does under a Prowlarr URL without user info, and a new
  reservation no longer stores the user info. Before, each client refused every link on the
  Prowlarr URL's own scheme, host and port, so none of them downloaded. A reservation made before
  this update for such a link still holds the user info, and Cinder drops it without downloading
  it on the first pass that hands the link to its download client. Searches still go to the
  Prowlarr URL as you set it.
