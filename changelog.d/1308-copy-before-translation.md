### Fixed
- **With a LibreTranslate URL set, when OpenSubtitles has no match for a missing subtitle and no
  embedded track in the wanted language passes the timing check, Cinder now fills it by copying
  a subtitle file in that language beside the video that it can use, such as `Movie.fre.srt` for
  French, before it tries to translate the video's default subtitle track (#1308).** When
  OpenSubtitles has no match for a missing subtitle and no embedded track in the wanted language
  passes the timing check, Cinder can translate the video's default subtitle track, or copy a
  subtitle file in that language saved under another name. With a LibreTranslate URL set, Cinder
  tried the default track first. When that track was in another language, parsed and passed the
  timing check, Cinder did not look at such a file: the subtitle became a machine translation,
  and when LibreTranslate failed Cinder wrote none. Cinder now looks for a file to copy first,
  with the same rules as before: it never takes a forced file, prefers a file with no SDH, CC or
  HI flag, and passes over one it cannot read or that fails the timing check. When it copies a
  file, it does not extract the default track from the video for that subtitle and does not call
  LibreTranslate for it. Only when it copies none does it translate the default track, then a
  subtitle file in another language, as before. This change does not replace a subtitle Cinder
  translated earlier while such a file sat beside the video.
