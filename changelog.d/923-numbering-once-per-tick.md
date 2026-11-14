### Internal
- **The TV sweep reads a series' numbering inputs once per visit (#923).** When one tick
  searches several seasons of a standard series, it reads the series' episode coordinates and
  its wanted seasons once, not once per season. A season the tick grabs stays a native season
  for the series' later seasons until the next tick. When that shared read fails, the tick skips
  the whole series, where it used to skip only the season whose read failed.
