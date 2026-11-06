### Fixed
- **The LibreTranslate timeout setting now works above 60 seconds (#1200).** A translation
  batch still stopped after 60 seconds when "LibreTranslate timeout (milliseconds)" in Settings,
  or `LIBRETRANSLATE_TIMEOUT`, was set higher, so a batch that a slow LibreTranslate server needed
  longer for always failed. The setting now limits each batch's whole request to LibreTranslate.
  When the log shows `subtitle translation failed` with `:request_timeout`, raise it.
