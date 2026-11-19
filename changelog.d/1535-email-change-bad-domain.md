### Fixed
- **Asking to change your email no longer crashes the account settings page on an install with
  no SMTP host, or for an address whose domain the SMTP mailer cannot encode (#1535).** On an
  install with no SMTP host, the page crashed each time Cinder tried to send the confirmation
  mail for an email change. With SMTP set up, it crashed when the new address's domain was one
  the mailer cannot encode, such as `x@-bad.com`. In both cases the page now shows the same
  message as when the mail goes out, and the server logs a warning that names the failure but
  not the address or the confirmation link. No mail goes out in either case, so an email change
  still needs SMTP set up in `/settings`.
