### Fixed
- **A subtitle file named with a generic Chinese code, such as `Movie.chi.srt` or
  `Movie.zho.srt`, now reads as Chinese (`zh`) instead of Cantonese (`cn`), so with Chinese set as
  `zh` the fallback for a missing Chinese subtitle can copy it instead of translating it into
  Chinese (#1343).** Cinder read a subtitle file whose language code is `chi` or `zho`, also with
  a region tag or a flag such as `Movie.chi-TW.srt` or `Movie.chi.forced.srt`, as Cantonese. An
  import placed it next to the video as `<video>.cn.srt` and recorded `cn` as its language, and
  with Chinese set as `zh` and a LibreTranslate URL set, Cinder could translate it into Chinese.
  An import now records `zh` for `Movie.chi.srt` and places it as `<video>.zh.srt`, unless the
  download also holds a file named as Chinese with the same flags and extension, such as
  `Movie.zh.srt`: the two then take the same name, Cinder places one of them and logs
  `sidecar link rejected` for the other. So with
  Cantonese set, such a file no longer becomes the Cantonese subtitle at import: with `cn` set the
  import placed it as that subtitle, and with `yue` or `cantonese` set the fallback for a missing
  Cantonese subtitle could copy the placed `<video>.cn.srt` to it. Cinder now looks for the
  Cantonese subtitle as for any missing one, and with a LibreTranslate URL set it can translate
  the placed `<video>.zh.srt` into Cantonese. With Cantonese set as `cn`, `yue` or `cantonese`,
  the fallback still copies a lone `Movie.chi.srt` or `Movie.zho.srt` beside the video to the
  Cantonese subtitle when it can use it, as it copies any file in the wanted language, and never
  copies a file named as Chinese, such as `Movie.zh.srt` or `Movie.cmn.srt`, to it. A subtitle
  already in the library as `<video>.cn.srt` keeps that name and still counts as Cantonese.
