### Fixed
- **`/healthz` no longer reads a busy poller as stale (#1294).** A movie, TV or book poller tick
  that searches many titles one after another, as after a rehunt re-queues parked titles, ran for
  minutes and `/healthz` answered `503 Poller stale` meanwhile, so Docker marked the container
  unhealthy. With polling enabled, `/healthz` now counts a poller in the middle of a tick healthy
  as long as the tick keeps making progress (a title, download or import starting or finishing,
  or one of its requests to a service starting or ending), and counts it stuck, a reason that
  reads `<poller> stuck: …`, once the tick goes 10 minutes with none. A poller between ticks is
  judged as before: unhealthy once its last tick, or its start when it has finished none, is more
  than 3 poll intervals old. The
  database-volume check is unchanged.
