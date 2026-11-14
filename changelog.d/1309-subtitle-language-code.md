### Fixed
- **A subtitle file such as `Movie.fr-FR.srt` now counts as French, and with French set as `fra`
  the fallback for a missing French subtitle copies a file such as `Movie.fre.srt` instead of
  translating it into French (#1309).** Cinder
  read a subtitle file whose name ends in a language with a region or script tag, such as
  `Movie.fr-FR.srt`, `Movie.pt-BR.sdh.srt` or `Movie.zh-Hant.srt`, as no language. An import
  placed such a file next to the video under `und`, as `<video>.und.srt` or
  `<video>.und.sdh.srt`, and recorded `und` as its language. Cinder now reads it as its base
  language: an import places `Movie.fr-FR.srt` as `<video>.fr.srt` and `Movie.pt-BR.sdh.srt` as
  `<video>.pt.sdh.srt`. Names such as `Movie.francais.srt`, `Movie.VF.srt` or `Movie.x264-GRP.srt`
  still read as no language, and a subtitle already in the library as `<video>.und.srt` keeps
  that name. Cinder can fill a missing subtitle by copying a subtitle file beside the video that
  is in the wanted language. It took a file only when the code it read from the file's name was
  the code in the subtitle languages setting, letter for letter apart from case. So `Movie.fr-FR.srt` with French
  set as `fr`, `Movie.fre.srt` with French set as `fra`, or `Movie.pt-br.sdh.srt` with Portuguese
  set as `pt-br` was not copied, and with a LibreTranslate URL set Cinder could translate it into
  its own language. The copy now compares languages, and ignores a region or script tag on either
  side: with `fr` set it takes `Movie.fr-FR.srt`, with `fra` or `french` it takes `Movie.fre.srt`,
  and with `pt-br` it takes `Movie.pt.srt`, `Movie.pt-PT.srt` or `Movie.pt-BR.srt`. Cinder still
  names the copy after the code as set, in lowercase, such as `Movie.fra.srt` or `Movie.pt-br.srt`. A file the
  copy would take for a language is never a translation source for that language.
