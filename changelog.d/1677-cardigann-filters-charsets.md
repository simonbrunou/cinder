### Internal
- **The Cardigann engine runs 18 more field filters, reads .NET-only patterns and holds nine legacy
  charsets (#1677).** `Filters` now runs `querystring`, `timeparse`, `prepend`, `tolower`,
  `toupper`, `base64decode`, `base64encode`, `urldecode`, `urlencode`, `htmldecode`, `htmlencode`,
  `timeago`, `reltime`, `validfilename`, `diacritics`, `validate`, `hexdump` and `strdump`, after
  Prowlarr's rules; `hexdump` and `strdump` log nothing. `BoundedRegex` translates `\uXXXX`, the
  block names `IsCyrillic` and `IsCJKUnifiedIdeographs`, `\s` and `\S` as .NET's white space and a
  `-` after a class escape before it compiles a pattern. `Charset` encodes and decodes
  `windows-1250`, `windows-1251`, `windows-1252`, `windows-1255`, `windows-1256`, `windows-874`,
  `ISO-8859-1`, `ISO-8859-2` and `tis-620` from the Unicode mapping files, so a character a charset
  lacks encodes as `?`, or `??` past U+FFFF, where .NET can write a near letter. The definition
  loader no longer reports those 18 filters, or the row filter `strdump`, as not supported, and its
  revision is now 3. `LoadCheck` adds `{:regex, :dotnet_only}` for a .NET balancing group, a class
  subtraction or a `(?` group outside an allowlist, such as `(?x)` or `(?(`, and
  `{:regex, :invalid}` for any other `regexp` or `re_replace` filter pattern the engine refuses; a
  `re_replace` inside a template is not checked at load. `fuzzytime`, `jsonjoinarray` and every
  non-UTF-8 `encoding` still read as not supported. No search calls these modules yet.
