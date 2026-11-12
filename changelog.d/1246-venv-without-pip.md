### Changed
- **The image's ffsubsync environment no longer holds pip (#1246).** The release image uninstalls
  pip from `/opt/ffsubsync` once ffsubsync is installed, since Cinder never runs it there.
