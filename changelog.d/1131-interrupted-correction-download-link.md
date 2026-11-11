### Fixed
- **A recovery that records an interrupted subtitle correction now tries to drop the hidden link
  to a download's file that the correction kept (#1131).** A subtitle that came with a release may
  be a hardlink to the file in its download folder. When Cinder was stopped at one exact step of
  correcting such a subtitle's timing, the hidden `.cinder-subtitle-sync-cas-*` folder beside the
  subtitle kept a second name for the download's file beside an empty file, so deleting the
  download no longer freed it. Now a recovery that records the interrupted correction tries to drop
  that name and remove the folder, also when the download's file was deleted first. When that name
  is the file's last, the folder stays if the recovery cannot read the file or finds there other
  bytes than the subtitle's from before the correction, and the recovery logs its path. When Cinder
  analyzes the subtitles of a video it manages, once that video's interrupted resets and
  replacements have finished, it also tries to remove such folders in the video's folder that no
  subtitle record there names, such as one left behind before this fix or one it failed to remove
  earlier, once the folder and its files have not changed for an hour, up to 50 per analysis. It
  removes none while a subtitle manifest in the video's folder cannot be read or decoded, or holds
  a record Cinder cannot decode or a record on a track with no subtitle file. The analysis leaves
  such a folder while it holds the file's last name, as it does when the download's file was
  deleted and no third name was left. A removal that fails leaves the folder in place and logs its
  path. While the download has its file, its bytes stay as they are throughout.
