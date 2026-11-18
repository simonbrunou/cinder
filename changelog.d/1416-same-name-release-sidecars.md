### Fixed
- **When a download holds two subtitle files that an import places under one name, such as
  `Movie.zh.srt` and `Movie.chi.srt`, or `Movie.fr.srt` and `Movie.fr-FR.srt`, Cinder now tries
  them in a fixed order instead of the order the folder listing gave (#1416).** An import places
  a subtitle file from the download next to the video under a name built from its language, flags
  and extension, such as `<video>.zh.srt`, so `Movie.zh.srt`, `Movie.chi.srt` and
  `Movie.zh-Hans.srt` all take `<video>.zh.srt`. Only one of them can land there, and which one
  depended on the order of the folder listing. Cinder now tries first a file named with the code
  the library name uses (`Movie.zh.srt`), then one named with another code or a language name
  (`Movie.chi.srt`), then one with a region or script tag (`Movie.zh-Hans.srt`), and among those
  of one kind the name that sorts first, so `Movie.pt-BR.srt` before `Movie.pt-PT.srt`. It places
  the first file that lands and logs each other one at info level. When a link finds that name
  already taken in the library, Cinder logs `sidecar link rejected: :eexist` and tries no other
  file for that name.
