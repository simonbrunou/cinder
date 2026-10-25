### Fixed
- **A Test button on `/settings` or `/setup` stops waiting after 15 seconds (#826).** A service
  whose health check hangs now reads "Unreachable" with the reason "Timed out" once the
  15-second budget the `/dashboard` rows and "Save & validate" already use runs out, and the page
  answers again, instead of waiting on the service with no limit.
