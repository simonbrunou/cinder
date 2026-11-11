### Fixed
- **Cinder now tries to remove a hidden folder left holding a second name for a download's
  subtitle file (#1187).** A subtitle that came with a release may be a hardlink to the file in
  its download folder. When such a subtitle was replaced, or could not be opened, right after
  Cinder wrote a corrected timing over it, Cinder drops the hidden `.cinder-subtitle-sync-cas-*`
  folder's name for the download's file by renaming an empty file over that name. When it could
  not create that empty file, or could not open the folder's name to check it first, the folder
  could keep that second name for as long as the download kept its file, and deleting the
  download did not free the file's space while the folder kept it. Now, when Cinder analyzes the
  subtitles of a video it manages, it treats a folder whose only file has another name as it
  treats one whose file has none (#1149). It tries to remove the folder once that video's
  interrupted resets and replacements have finished, when the folder and its file have not
  changed for an hour, no subtitle record there names it, and the file holds the bytes of a
  subtitle Cinder manages in that folder or of that subtitle's immutable original. It removes up
  to 50 such folders per analysis, and none while a subtitle manifest there cannot be read or
  decoded, or holds a record Cinder cannot decode or a record on a track with no subtitle file.
  Removing the folder drops only its own name for the file, so the download keeps the file and
  its bytes. A removal that fails leaves the folder in place and logs its path. A folder whose
  file holds bytes no such subtitle holds stays.
