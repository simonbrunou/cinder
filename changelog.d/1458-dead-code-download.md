### Internal
- **Three functions that only tests called are gone (#1458).**
  `HTTPPolicy.validate_source_url/2,3`, `Download.submit_intent/1` and
  `Download.EndpointVetter.max_hosts/0` had no caller outside the tests. Their tests now check the
  same cases through `HTTPPolicy.source_request_target/3`, `Download.reconcile_intent/1` and
  `EndpointVetter.allowed_hosts/3`. Which URLs and hosts Cinder accepts, and how it submits a
  download, are unchanged.
