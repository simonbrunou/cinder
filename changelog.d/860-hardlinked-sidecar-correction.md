### Fixed
- **A subtitle correction no longer empties the download's copy of a release subtitle (#860).**
  A subtitle that came with a release folder may be imported as a hardlink to the file in its
  download folder. When a subtitle sync corrected such a subtitle, Cinder emptied the download's
  file, which breaks a torrent still seeding it, and a reset did not bring it back. A correction
  and a reset now leave that file's bytes alone. Cinder does not repair a download file an
  earlier correction already emptied: recheck that torrent in your client.
