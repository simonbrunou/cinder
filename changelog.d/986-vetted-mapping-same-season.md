### Fixed
- **A season's search no longer grabs a release that your episode mapping gives to another
  episode of the same season (#986).** Matching a leftover file named "S02E05" to S02E07 by hand
  can leave a mapping that reads "S02E05" as S02E07. Season 2's own search then still grabbed
  "Show.S02E05" or the "Show.S02" pack for its native S02E05. Now the automatic search skips
  both, the upgrade search no longer grabs "Show.S02E05" to replace native S02E05's file, and
  season 2's "Find a better match" panel lists both as "conflicting episode numbering" and
  refuses to grab them. "Show.S02E07" is still grabbed for S02E07. A mapping Cinder derived on
  its own still keeps the native reading.
