### Fixed
- **A failed rename while correcting a subtitle no longer keeps a hidden link to a download's
  file (#1156).** A subtitle that came with a release may be a hardlink to the file in its
  download folder. One step of correcting such a subtitle's timing renames an empty file over the
  hidden `.cinder-subtitle-sync-cas-*` folder's name for the download's file. When that rename
  failed, the folder beside the subtitle kept that second name, so deleting the download no
  longer freed the file. Cinder now leaves that folder as a correction stopped just before the
  rename leaves it (#1131), and tries to remove that name and the folder the same way while the
  download still has its file. It tries when it finishes the correction. When the correction
  stopped instead because the subtitle was replaced meanwhile, or because Cinder could not open
  it right after writing it, it tries when it analyzes the subtitles of that video, once that
  video's interrupted resets and replacements have finished and the folder and its files have not
  changed for an hour, up to 50 such folders per analysis. A removal that fails leaves the folder
  in place and logs its path. The download's bytes stay as they are throughout. A folder whose
  download file was deleted first stays, since it holds that file's last name. So does a folder
  this rename left before this fix, which holds only the download file's second name.
