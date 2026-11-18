### Internal
- **Six subtitle functions that only tests called are gone (#1459).**
  `Sync.manual_from_anchors/2`, `Sync.Worker.enqueue_units/1,2`,
  `Manifest.clear_backup_tombstone/2`, `Manifest.provisional?/3`, `Manifest.reset_cleanup_sync/2`
  and `SidecarTransaction.backup_path/1` had no caller in Cinder's own code. The worker no longer
  answers the synchronous enqueue call that only `enqueue_units` sent. Subtitle sync, its timestamp
  anchors and the manifest's reset journal work as before.
