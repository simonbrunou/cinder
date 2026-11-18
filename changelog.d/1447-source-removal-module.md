### Internal
- **Source removal lives in `Cinder.Download.SourceRemoval` (#1447).** The functions that remove
  a download's client job and payload after an import, and retire a book grab, moved out of
  `Cinder.Download`, and their callers call the new module directly. Where a cleanup intent is
  recorded for a client removal, the removal still runs only after it, and what Cinder removes is
  unchanged.
