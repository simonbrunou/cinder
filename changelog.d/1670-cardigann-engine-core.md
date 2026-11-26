### Internal
- **The pure core of Cinder's Cardigann engine (#1670).** Four modules under
  `Cinder.Acquisition.Indexer.Cardigann` evaluate Prowlarr's template subset (`Template`), read
  .NET custom date formats (`DotnetDate`), run the field filters Nyaa.si and Torrent9 use and the
  `andmatch` row filter (`Filters`), and run every pattern with a match limit (`BoundedRegex`).
  One output byte cap of 64 KiB covers a template and a whole filter chain. Until #1671, no
  search called them, and the definition loader reported the filters Nyaa.si and Torrent9 use as
  not supported.
