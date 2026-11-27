### Internal
- **The Cardigann engine runs the `fuzzytime` filter, and a row's `date` field reads dates such as
  `Yesterday 14:22` or `Wed, 25 Nov 2026 13:02:00 +1` (#1802).** `DotnetDate.from_unknown/2` now
  reads more of the forms Prowlarr's `DateTimeUtil.FromUnknown` reads, such as `2 hours ago`,
  `Today 10:01 PM`, `Tomorrow 14:22:10 +08:00`, `Monday at 14:22`, `Nov 25`, `11/25/2026` (month
  first) and `25 Nov 2026 14:22`. Before, it read only Cinder's own ISO text, a Unix time and
  text holding `now`. It is `:error` on some text Prowlarr reads, such as `Today 14:22 +0800`,
  `Today 14:5`, or `Jan 1` followed by 4,000 blanks and `x 14:22`, on which a pattern hits its
  match limit. A time that names no offset reads as UTC, and `Today` or `2 hours ago` counts from
  Cinder's clock. A row's `date` field and its `dateheaders` header read through
  `from_unknown/2`: a `date` field it cannot read leaves the row with no date of its own. A row
  with no date of its own takes its `dateheaders` header's date, and a header `from_unknown/2`
  cannot read then drops the row. `fuzzytime` writes the time it reads, or fails the filter.
  505 of the 584 v11 definitions at Prowlarr/Indexers `56b20b19` load where 488 did, among them
  `1337x`, `mikan` and `rintornet`. The loader raised its revision to 10.
