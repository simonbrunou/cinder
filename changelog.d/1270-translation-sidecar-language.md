### Fixed
- **With French set as `fr`, a subtitle file whose name Cinder reads as French, such as
  `Movie.fre.srt`, is no longer translated into French, and a subtitle file that fails is passed
  over for the next one as a translation source (#1270).** This entry assumes each subtitle
  language is set as the code Cinder reads from a subtitle file's name for that language, such as
  `fr`, which it reads from `Movie.fre.srt`. With a LibreTranslate URL set, Cinder can fill a
  missing subtitle by translating a subtitle file beside the video. It does so only when it has
  found none whose name it reads as that language that it can copy. The translation took the first
  `.srt` file listed beside the video that was neither forced nor the subtitle being filled,
  whatever its language. That could be the very file the copy had just skipped: when the copy
  could not read it but the translation could, Cinder wrote it as a translation into its own
  language. A first file that could not be read, failed the timing check or did not parse kept
  Cinder from translating any file listed after it. One subtitle fetch also kept the result of
  that first file for every wanted language, so a file named as German, such as `Movie.deu.srt`,
  translated into French could then be translated into German. When it looks for a file to
  translate, Cinder now picks, for each wanted language, the first `.srt` file listed that is
  neither forced nor the subtitle being filled, whose name Cinder does not read as that language,
  and that it can read, that passes the timing check and that parses. A file whose name holds no
  language Cinder recognizes, such as `Movie.srt`, can still be translated into any wanted
  language, whatever language it holds. Cinder does not rewrite a subtitle it translated earlier
  from a file in its own language.
