### Fixed
- **A season's search no longer grabs a release that your episode mapping says belongs to
  another season (#924).** When a season offset you saved, or a file you matched to an episode by
  hand, reads a code such as "S02E05" as another season's episode (S01E33), season 2's own search
  used to grab "Show.S02E05" or the "Show.S02" pack for its native S02E05 anyway, and the import
  filed S01E33's content under S02E05. The automatic search and the upgrade search now skip those
  releases, and season 2's "Find a better match" panel lists them as "conflicting episode
  numbering" and refuses to grab them. A mapping Cinder derived on its own still keeps the
  native reading.
