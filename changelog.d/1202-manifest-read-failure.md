### Fixed
- **A read error on a subtitle manifest file no longer costs the other languages their records
  (#1202).** When reading a video's subtitle manifest file returned an error other than a missing
  file, such as a timeout of Cinder's filesystem helper, each manifest write started from an empty
  manifest. A new subtitle for one language could then rewrite the manifest with that language
  alone, and marking a release sidecar could replace a hash-verified subtitle's record and drop
  its sync record. When the read a manifest write starts from fails this way, the write now
  changes nothing, fails, and logs `subtitle manifest cannot be read` with the video and the
  reason. Release-sidecar marking whose read fails this way leaves that language unmarked, with a
  warning. A write still starts from an empty manifest when the manifest reads but does not
  decode, as before.
