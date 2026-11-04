### Fixed
- **An interrupted subtitle correction no longer keeps a hidden link to a download's file
  (#1131).** A subtitle that came with a release may be a hardlink to the file in its download
  folder. When Cinder was stopped at one exact step of correcting such a subtitle's timing, the
  hidden `.cinder-subtitle-sync-cas-*` folder beside the subtitle kept a second name for the
  download's file, so deleting the download no longer freed it. While the download still has its
  file, Cinder now tries to remove that name and the folder when it finishes the interrupted
  correction. When Cinder analyzes the subtitles of a video it manages, once that video's
  interrupted resets and replacements have finished, it also tries to remove such folders in the
  video's folder, up to 50 per analysis: one left behind before this fix, or one it failed to
  remove earlier, once the folder and its files have not changed for an hour. A removal that
  fails leaves the folder in place and logs its path. The download's bytes stay as they are
  throughout. A folder whose download file was deleted first stays, since it holds that file's
  last name.
