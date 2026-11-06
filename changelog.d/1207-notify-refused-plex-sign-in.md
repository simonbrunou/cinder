### Added
- **Admins hear when Cinder refuses a known user's Plex sign-in (#1207).** A signed-in user's
  Plex link from `/users/settings` refused after plex.tv approved its PIN, and a Plex sign-in
  refused after plex.tv named a Plex account that a user has linked, each send one
  `sign_in_refused` notice naming that user and the step that refused it, at most one per user per
  hour. The count is held in memory, so it starts over when Cinder restarts. On Discord the notice
  shows the user's Plex or Jellyfin username with every character but letters, digits and
  `._%+'@-` removed, or `user #<id>`, and the step in words. The generic webhook gets
  `{"event": "sign_in_refused", "id": <user id>, "reason": "<step>"}`. Neither gets the user's
  email, and Cinder sends no email for it. Nothing is sent for a sign-in with a Plex account no
  user has linked, for a link that waits on the password being entered again, or for the refusal
  that keeps an admin from signing in with Plex, since admins sign in with their password. An
  admin refused at an earlier step, such as the server check, gets a notice like anyone else.

### Fixed
- **A failing notifier no longer logs a user's email (#1207).** When the notifier itself fails,
  its warning line names the event by its type and, when it has them, its ids, such as
  `sign_in_refused #7`, instead of printing the whole event, which for an account event held the
  user's email and username.
