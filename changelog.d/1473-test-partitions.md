### Internal
- **A bare `mix test` runs the suite in 4 parallel partitions unless `CINDER_TEST_PARTITIONS`
  says otherwise (#1473).** After its compile, format and Credo gates, it starts
  `CINDER_TEST_PARTITIONS` processes (4 when unset), each with its own test database file and its
  own copy of the build folder, and exits non-zero when any partition fails.
  `CINDER_TEST_PARTITIONS=1`, a path argument, or a switch such as `--failed` runs one process.
