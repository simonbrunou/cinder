### Fixed
- **Subtitle corrections on mergerfs repair duplicate backup leftovers again (#972).** mergerfs
  refuses to open its `.mergerfs` control file for reading, so Cinder could not read the mount's
  branch list. A subtitle correction whose empty backup leftover sat on two mergerfs branches
  then stayed failed until someone deleted the duplicate by hand. Cinder now reads the control
  file the way mergerfs serves it, removes the empty duplicate it proves its own, and finishes the
  correction. Run the sync again for a track whose correction failed this way.
