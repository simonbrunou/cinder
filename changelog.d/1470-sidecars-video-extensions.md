### Internal
- **Sidecar lookup reads the importers' video list (#1470).** `Cinder.Library.Sidecars.files/1`
  no longer keeps its own copy of the video containers. It reads `Cinder.Library`'s list through
  `video_extensions/0` and `video_file?/1`, as `Cinder.Download.ContentPolicy`'s default video
  media list does since #1448. A video in a container added to that list is then a source
  `files/1` lists sidecars for, and counts as a video when `files/1` checks whether its folder
  holds one video, the case where a sidecar's name need not start with the video's. The copy held
  the same seven containers as the list, so what `files/1` lists today is unchanged.
