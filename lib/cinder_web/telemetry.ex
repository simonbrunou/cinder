defmodule CinderWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller emits VM measurements (+ the disk gauge below) every 10_000ms.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def periodic_measurements do
    [
      {__MODULE__, :dispatch_disk_measurements, []}
    ]
  end

  @doc """
  Emits `[:cinder, :disk]` for every monitored root (`Cinder.Disk.monitored_roots/0`: the library
  roots plus the `:database` volume holding `cinder.db` + its `-wal`). A root that can't be read
  (unmounted, permission denied) is skipped rather than crashing the poller — the next tick tries
  again.
  """
  def dispatch_disk_measurements do
    for {kind, path} <- Cinder.Disk.monitored_roots() do
      case Cinder.Disk.stats(path) do
        {:ok, stats} ->
          :telemetry.execute([:cinder, :disk], stats, %{root: kind, path: path})

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("cinder.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("cinder.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("cinder.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("cinder.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("cinder.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Domain Metrics — the Catalog.transition/transition_episode choke-points, the shared
      # poller skeleton's per-tick timing, each poller's terminal-park choke-point, and outbound
      # HTTP through Cinder.HTTPPolicy.bounded_request/2,3.
      counter("cinder.transition.count",
        tags: [:kind, :to],
        description: "Pipeline state transitions, by kind (movie/episode) and target status"
      ),
      summary("cinder.poller.tick.duration",
        tags: [:poller],
        unit: {:native, :millisecond},
        description: "Time spent in one poller tick (do_poll/1 or do_poll/0)"
      ),
      counter("cinder.park.count",
        tags: [:kind, :reason],
        description: "Terminal parks, by kind (movie/episode) and reason"
      ),
      summary("cinder.http.request.duration",
        tags: [:host, :status],
        unit: {:native, :millisecond},
        description: "Outbound HTTP via Cinder.HTTPPolicy.bounded_request/2,3"
      ),

      # Disk gauge — the last-known free/total bytes per monitored root (library roots + the
      # `:database` volume).
      last_value("cinder.disk.free_bytes",
        tags: [:root],
        unit: :byte,
        description: "Free bytes on a monitored root"
      ),
      last_value("cinder.disk.total_bytes",
        tags: [:root],
        unit: :byte,
        description: "Total bytes on a monitored root"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end
end
