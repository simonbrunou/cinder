### Fixed
- **Reopen refuses a denied series or episode request no approval can create (#809).** A whole
  series or single episode request filed before Cinder stopped accepting them could be reopened
  from `/requests` after a deny, then sat in the approval queue with no admin able to approve it.
  Reopen now leaves such a request denied, with its denial reason, and says "This kind of request
  isn't supported yet." To get the show, request its seasons from the show's discovery page
  (`/series/tmdb/:tmdb_id`); an admin can delete the old request on `/requests`. Reopening a
  denied movie, season or book request works as before.
