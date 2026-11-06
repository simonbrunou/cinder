### Added
- **A refused Plex, Jellyfin or OpenID sign-in names its step in the log (#1206).** Each refused
  sign-in or account link now writes one warning line that starts with `plex_signin refused`,
  `jellyfin_signin refused` or `oidc_signin refused`, then names the step that refused it and the
  reason, for example
  `plex_signin refused intent=login step=server_access plex_id=42 resources=3 reason=forbidden`.
  Search the log for `_signin refused` to see why someone could not sign in. A failed account
  write shows its one-word reason, such as `no_email`, or only the names of the fields it
  rejected. An error struct shows its type, followed in parentheses by at most a short code such
  as `timeout` or `access_denied` or the type of the error it wraps; its response and its message
  never print. An error message from the OpenID library prints as its fixed text with each value
  it names shown as `<value>`, such as `"Invalid issuer <value> in ID Token"`, and any other text
  prints as `string`.
