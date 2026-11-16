### Fixed
- **Subtitle sync no longer skips a subtitle Cinder downloaded or took from the video's own track
  for a language set as `fra`, `french` or `pt-br` because its file name reads as another code
  (#1344).** Cinder names a subtitle it downloads from OpenSubtitles or extracts from the video's
  own subtitle track after the code in the subtitle languages setting, in lowercase, such as
  `Movie.fra.srt`, and records it under that code. Subtitle sync looked for that record under the
  code it read from the file's name, `fr` for `Movie.fra.srt` and `pt` for `Movie.pt-br.srt`, so
  it never listed `Movie.fra.srt` with its `fra` record: the subtitle sync page did not show it
  and automatic sync never analysed it. Subtitle sync now finds a subtitle's record by the file
  name the record holds, so it lists `Movie.fra.srt` under `fra`, as it lists `Movie.fr.srt`
  under `fr`, and analyses it. This covers such subtitles already in the library. When two
  records name the same file, it lists that file under neither.
