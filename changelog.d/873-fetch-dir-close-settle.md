### Fixed
- **A temporary folder that fails to close no longer stops a new subtitle from being recorded
  (#873).** When Cinder could not confirm a new subtitle file and the temporary folder it wrote
  the file through then failed to close, Cinder reported the subtitle as failed and recorded
  none, even when the file held the new bytes. It now records the subtitle whenever it would
  have without the folder failure.
