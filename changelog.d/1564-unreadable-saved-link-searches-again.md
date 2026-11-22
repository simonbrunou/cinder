### Fixed
- **A searching movie no longer stops at Search failed on the saved download link of an earlier
  grab that Cinder can no longer read, when the movie's own search reaches that link while
  Cinder's retry of saved links has not handled it yet (#1564).** Cinder saves the link of each
  release it hands to the download client, and hands the release over again later when the first
  try failed for a reason that can pass, such as a timeout. When the download client answers that
  it does not hold the release yet and Cinder can no longer read its saved link, Cinder drops the
  link and the movie goes back to searching, where a release a search finds is grabbed as after
  any other search. Before, the movie stopped at Search failed when its own search reached the
  saved link first: when Cinder's retry of saved links stopped on an error with another movie's
  link earlier in the same poll, or when the link's retry came due during that poll. The release
  that new search grabs can still stop the movie at Search failed, as any grab can, for example
  when the client refuses it for good or when its own link cannot be read back either.
