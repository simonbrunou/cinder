### Fixed
- **Cinder now tries to remove the old subtitle an interrupted correction or reset left in a
  hidden folder (#1149).** When Cinder was stopped, or one step failed, after it swapped a
  corrected or reset subtitle into place and before it emptied the old subtitle's file in the
  hidden `.cinder-subtitle-sync-cas-*` folder beside it, that file could keep the old subtitle for
  good. After a reset interrupted right after its swap, a later reset of the same correction could
  fail. Now, while the interrupted correction's or reset's subtitle record still names that
  folder, a recovery that records the interrupted correction and a reset that finishes on the
  same video both try to empty that file first, or to drop the folder's name for a download's file, also when the
  download's file was deleted first or the empty file that replaces that name could not be
  created. A file they cannot read stays, and only the correction's recovery then logs the
  folder's path. When emptying the file or dropping that name fails, the folder stays and Cinder
  logs its path, and still records the interrupted correction. When Cinder analyzes the subtitles
  of a video it manages, once that video's interrupted resets and replacements have finished, it
  also tries to remove such folders in the video's folder, up to 50 folders per analysis: one
  whose only file has no other name and holds the bytes of a subtitle Cinder manages in that
  folder or of that subtitle's immutable original, once the folder and its file have not changed
  for an hour and no subtitle record there names it. A folder whose bytes match no such file
  stays. When the video's folder holds such hidden folders and a subtitle manifest there cannot
  be read or decoded, or holds a record Cinder cannot decode or a record on a track with no
  subtitle file, that analysis removes none of them and logs one
  `subtitle workspaces not swept in <folder>` warning.
