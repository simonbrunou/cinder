### Fixed
- **The admin pages no longer offer Approve or Reopen on a legacy series or episode request
  (#883).** A whole series or single episode request filed before Cinder stopped accepting them
  showed an Approve button and a media profile picker on `/requests` and in the dashboard's
  approval queue, and a Reopen button once denied, though no approval can create it: pressing
  one only answered "This kind of request isn't supported yet." These rows now offer only Deny
  (while pending) and Delete. Movie, season and book requests show the same actions as before.
