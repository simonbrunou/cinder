### Added
- **Sign in with a passkey (#1560).** A signed-in user can add passkeys in Account settings,
  section Passkeys, and rename or delete each one there. Adding or deleting a passkey needs a
  recent sign-in. The log-in page offers "Sign in with a passkey" to everyone, with no email to
  type first, and signs in the owner of a passkey added this way. A passkey is one more way to
  sign in, beside the methods the install already offers, and not a second factor. Cinder accepts
  a passkey only when the authenticator has checked the user, by PIN, fingerprint or face. A
  signed-in user can also use their own passkey on the log-in page to renew the recent sign-in.
  Passkeys work only at `https://$PHX_HOST`, so browsers must reach the install over https under
  the domain name in `PHX_HOST`; an IP address or plain http cannot hold one. The data export
  lists each passkey's name and dates. `docs/operating.md` says how to add one.
