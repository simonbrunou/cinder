### Internal
- **The media server's product name comes from its settings option (#805).** Each
  `media_server_type` option carries its `name`, and the movie, series and My requests pages read
  it through `Cinder.Settings.media_server_name/1` instead of each spelling "Plex" and "Jellyfin".
  The "Open in Plex" and "Open in Jellyfin" links read as before.
