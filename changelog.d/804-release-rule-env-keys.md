### Internal
- The release-rule readers (the size band and quality preferences the scorer gets, the upgrade
  sweep's preferred lists and cutoff, and the `/settings` cutoff check) take each env key from its
  setting definition instead of building it from the kind's name (#804). They read the same keys
  as before.
