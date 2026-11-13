### Internal
- The `cinder.transition.count` metric on `/admin/dashboard` now also counts the episode writes
  of `Catalog.create_grab`, `finish_grab`, `park_grab`, `reap_stalled_grab` and
  `delete_episode_file`: one per episode written, unless the announcement after the commit fails,
  which Cinder logs (#788). Before, those calls emitted no `[:cinder, :transition]` event. Episode
  adoption already counted.
