### Fixed
- **Movie and TV imports now count a file of up to 100 MiB named like `Show.S01E05` + no-break
  space + `sample.mkv` as a sample, as the anime import already did (#1452).** A no-break or
  ideographic space before `sample` or `preview` now delimits the word, as a dot does. When such
  a sample names the same episode as a real file, a TV import picks the real file for that
  episode, even when the sample is larger. A movie folder with no `.iso` image and no `BDMV` or
  `VIDEO_TS` folder, whose videos are all such samples, beside a RAR, ZIP or 7z archive, stops
  on the archive as a folder holding `sample.mkv` does, now also when a sample is at least as
  large as the archives together.
