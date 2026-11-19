### Security
- **A notification email that fails to send no longer writes the failure's reason, which can
  quote the recipient's address, to the server log (#1544).** When Cinder could not send one of
  its notification emails to a user, its warning quoted the mailer's failure reason or exception
  message, up to 500 bytes of it. For a recipient such as `reader@-bad.com`, it quoted the `-bad`
  part of the address. The warning now names only the failure's exception module or atom tag,
  such as `email notify exit: :bad_label`, or `(no tag)` when the reason has neither.

### Fixed
- **An email-change mail that the mailer reports as not sent now leaves a warning in the server
  log (#1543).** When the mailer returned an error instead of sending the mail, such as for an
  SMTP server that refuses the connection, Cinder logged no warning. It now logs one warning that
  names only the error's exception module or atom tag, else `(no tag)`, such as
  `update email delivery failed: :retries_exceeded`, without the address or the confirmation
  link.
