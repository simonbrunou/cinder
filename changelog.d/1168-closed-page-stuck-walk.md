### Fixed
- **Closing or reloading the download folders or library adoption page during a scan stuck on a
  wedged mount no longer starts one more stuck listing of the same folder on every reload
  (#1168).** A folder listing that is still waiting when its page closes now counts as stuck at
  once, as one that missed its time limit already did. Closing the page during a listing that is
  only slow also counts it as stuck until it returns.
