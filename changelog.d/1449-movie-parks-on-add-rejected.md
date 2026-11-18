### Changed
- **A movie that is still searching now parks at Search failed when the download client refuses
  to add the release its search has just picked (#1449).** A refusal is the client answering
  that it did not add the release, such as SABnzbd creating no job for it. Before, each refusal
  spent one of the movie's search attempts, and Cinder searched for the movie again until they ran
  out. A book is held on the same refusal, as before.
