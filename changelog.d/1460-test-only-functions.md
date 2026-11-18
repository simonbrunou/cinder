### Internal
- **Four public functions that only tests called are gone (#1460).** `Requests.assign_profile/2`,
  `Library.ImportStage.create!/1`, `LibraryKind.handling?/2` and
  `Library.BookArchive.Rar.available?/0` had no caller in the app. `Request.profile_changeset/2`,
  which only `Requests.assign_profile/2` called, is gone with it. A request still records its
  chosen profile when it is filed, and a profile of another media kind is still refused.
