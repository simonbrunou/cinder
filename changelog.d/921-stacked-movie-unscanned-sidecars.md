### Fixed
- **A movie in CD or part files no longer fails to import outside a forced upgrade when its
  record has a quality but no subtitle scan and a part's library file stays (#921).** A movie
  imported before Cinder recorded subtitle languages can have such a record. An import that was
  not a forced upgrade failed with an error when the library already held a part, either the
  download's own file or a file the download does not beat. It now records the subtitle
  languages of the parts it placed, and leaves the list unscanned when every part stayed. A
  forced upgrade, and a record with no recorded quality, were not affected.
