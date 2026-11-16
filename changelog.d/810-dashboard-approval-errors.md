### Fixed
- **The dashboard's approval queue says to sign in again when the approving admin's account was
  deleted (#810).** An approval refused because the admin's account was deleted while the page was
  open now says "Your admin account was deleted. Sign in again to approve requests." there, as
  `/requests` does. Once an approval has started, an error with no message of its own, such as a
  failed TMDB lookup, now says "Couldn't approve that request. Please try again." on the dashboard
  too.
