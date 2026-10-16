# Testing

- `mix test` decides when a task is done. Before you start, write the done-when as something
  `mix test` can check, then loop until it is green.
- A bug fix starts with a test that reproduces the bug. Then make it pass.
- New functionality, such as a choke-point, a state or a writer, ships with a test.
- Tests never hit the network or a real service. `config/test.exs` points each external-service
  behaviour at its Mox mock, so a test that needs service behaviour sets an expectation on the
  mock. The behaviour list is in [architecture.md](architecture.md).
