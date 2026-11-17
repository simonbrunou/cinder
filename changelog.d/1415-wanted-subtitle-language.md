### Internal
- **One module decides what counts as a wanted subtitle language (#1415).**
  `Cinder.Subtitles.WantedLanguage` now answers whether an embedded track or a sidecar file counts
  as a subtitle language from Settings, reads the language a sidecar's file name carries, and
  names the sidecars an import places and a fetch writes. `Cinder.Subtitles`,
  `Cinder.Subtitles.OwnTrack`, `Cinder.Subtitles.Sync.Reference` and `Cinder.Library.Sidecars` ask
  it instead of combining the language rules themselves. Which subtitles Cinder picks and the
  names it gives them are unchanged.
