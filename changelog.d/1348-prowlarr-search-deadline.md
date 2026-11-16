### Fixed
- **A Prowlarr search request that answers after 60 seconds but within 90 now returns its results
  (#1348).** Cinder gave each search request to Prowlarr 90 seconds to answer, but a request
  still running at 60 seconds ended there with a timeout. It now ends at 90 seconds.
