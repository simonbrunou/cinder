### Fixed
- **On an install with no SMTP host, the account settings page now says that email changes need
  mail set up, and refuses them (#1546).** Before, the page accepted a valid change request and
  said that a confirmation link had been sent, but with no SMTP host Cinder sends no mail, so the
  link never came. Now the email section shows "Email changes need mail set up. Ask an admin to
  set an SMTP host in Settings." and its Change email button is disabled. A change request that
  reaches Cinder anyway gets that message as an error, after the usual check that you signed in
  recently. Once an admin sets an SMTP host in `/settings`, the page offers email changes again
  on its next load.
