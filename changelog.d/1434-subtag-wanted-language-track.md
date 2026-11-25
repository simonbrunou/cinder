### Fixed
- **With a subtitle language set with a region or script tag, such as `pt-br` or `zh-hant`,
  Cinder now tries a non-forced subtitle track of the video in the base language, such as one
  tagged `por` or `chi`, for a subtitle in that language that is missing or that Cinder wrote,
  when the OpenSubtitles search returns no match (#1434).** Cinder counted a video's subtitle
  track for such a language only when the track's tag held the whole code, such as `pt-BR`. So
  with `pt-br` set, it never extracted a track tagged `por` or `pt` as the `pt-br` subtitle, as
  it does with `pt` set. When the search returns no match, the fallback for a subtitle that is
  missing or that Cinder wrote now also tries a non-forced track that the base language takes,
  such as `por` or `pt` for `pt-br`, and `zh`, `chi` or `zho` for `zh-hant`. It names one that
  extracts and passes the timing check after the code as set, such as `Movie.pt-br.srt`. A track
  tagged with another region, such as `pt-PT` for `pt-br`, still does not count. Subtitle sync
  can now also time a `pt-br` subtitle downloaded from OpenSubtitles against a `por` or `pt`
  track instead of the video's audio. On a later pass where the search again returns no match,
  a base-language track can replace a subtitle Cinder wrote earlier for that language, such as a
  translation or a subtitle OpenSubtitles matched by the movie's ID rather than by the file's hash.
