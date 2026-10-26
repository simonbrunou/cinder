### Fixed
- **Seasons only the old media server held become requestable again after a switch (#721).**
  After switching between Plex and Jellyfin, Cinder kept the old server's season list until the
  new server answered, so with a wrong API key or an unreachable server those seasons kept
  reading Available on the season request page, with no Request button, and the Discover, person
  and collection TV cards kept their badge. Cinder now counts only the seasons of the media
  server it runs against, whether you picked it in `/settings` or through `PLEX_URL`, and open
  pages update as soon as the switch is saved. A failed read from the same server still keeps
  its last list.
