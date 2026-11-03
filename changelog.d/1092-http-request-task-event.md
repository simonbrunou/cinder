### Internal
- Every outbound HTTP call now emits a `[:cinder, :http, :request_task]` telemetry event when
  its request task starts, carrying the task's pid and the caller's (#1092). The test of the
  request deadline finds the task through it, so a slow CI runner no longer fails that test.
  Requests and their deadlines behave as before.
