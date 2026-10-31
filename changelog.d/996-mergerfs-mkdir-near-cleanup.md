### Internal
- On a mergerfs pool, a directory create that loses the name to another create on the same branch
  removes the hidden `.<name>.cinder-create-<hex>` directory it made first, while that name still
  holds that empty directory, and still reports the failure as before (#996). No current Cinder
  caller reaches that race.
