### Security
- **Plex sign-in now admits only the account of the Plex token in your media server settings and
  the accounts on plex.tv's share list for your Plex server (#1212).** Signing in with Plex and
  linking a Plex account from the settings page admit a Plex account when it is the account of
  that token, or when plex.tv's share list for your Plex server, read with that token, holds it.
  Before, Cinder admitted any account whose devices on plex.tv included one that reported your
  server's id, a value each device reports to plex.tv itself. Use the server owner's token in
  your media server settings: Cinder treats that token's account as the owner. When Cinder cannot
  read the token's account it refuses the sign-in and logs `step=owner_account`. The token's own
  account signs in without the share list being read. For any other account, Cinder first reads
  your Plex server's id, as before, and refuses with `step=server_machine_id` when it cannot. A
  share list Cinder cannot read, including one that does not have the shape Cinder expects, then
  refuses the sign-in and logs `step=server_shares`. The admins hear of each refusal as they do of
  one at the server check. A `step=server_access` line now shows `shares=`, how many accounts
  the share list held, where it showed `resources=`.
