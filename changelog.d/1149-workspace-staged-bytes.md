### Fixed
- **A recovery that records an interrupted subtitle correction, and a reset that finishes on the
  same video, now try to remove the old subtitle that correction or reset left in a hidden folder,
  while the correction's or reset's subtitle record still names that folder (#1149).** When
  Cinder was stopped, or one step failed, after it swapped a corrected or reset subtitle into
  place and before it emptied the old subtitle's file in the hidden
  `.cinder-subtitle-sync-cas-*` folder beside it, that file could keep the old subtitle for good.
  After a reset interrupted right after its swap, a later reset of the same correction could fail.
  Now, while the interrupted correction's or reset's subtitle record still names that folder, a
  recovery that records the interrupted correction and a reset that finishes on the same video
  both try to empty that file first, or to drop the folder's name for a download's file, also when
  the download's file was deleted first or the empty file that replaces that name could not be
  created. When they read that file but emptying it or dropping that name fails, Cinder logs the
  folder's path, and the recovery still records the interrupted correction. When they cannot read
  the file an interrupted reset left, that file keeps its bytes and its folder stays, and they do
  not log the folder's path. Once the recovery records the interrupted correction, also when a
  reset runs that recovery first, it tries to remove the correction's folder while that folder
  holds only an empty file, or a file that still has another name, such as the download's, beside
  the empty file that replaces that name, which drops only the folder's name for that file. It can
  remove the folder even when it failed earlier to read that file or to drop that name. When the
  folder holds anything else, or the removal cannot open that file or fails, the folder stays and
  the recovery logs its path. When Cinder analyzes the subtitles of a video it manages, once that
  video's interrupted resets and replacements have finished, it also tries to remove such folders
  in the video's folder, up to 50 folders per analysis: one whose only file has no other name and
  holds the bytes of a subtitle Cinder manages in that folder or of that subtitle's immutable
  original, once the folder and its file have not changed for an hour and no subtitle record there
  names it. A folder whose bytes match no such file stays. When the video's folder holds such
  hidden folders and a subtitle manifest there cannot be read or decoded, or holds a record Cinder
  cannot decode or a record on a track with no subtitle file, that analysis removes none of them
  and logs one `subtitle workspaces not swept in <folder>` warning.
