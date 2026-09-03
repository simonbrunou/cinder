defmodule Cinder.PollerSupervisorTest do
  # async: false: temporarily stops the real, globally-named Cinder.PollerSupervisor (owned by
  # Cinder.Supervisor) to free its registered name for this test's own standalone instance.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Mirrors the real defect's exact shape: init/1 succeeds (so the supervisor's own start_link
  # never fails outright), then the handle_continue(:schedule, ...) path that PollerSkeleton runs
  # immediately after every (re)start raises — e.g. a bad `interval` reaching Process.send_after/3.
  # Crashes a bounded number of times (comfortably more than PollerSupervisor's own budget) via a
  # `:counters` reference that survives the crashing process's own restarts, then settles —
  # standing in for a transient cause clearing, so the test is fully deterministic instead of
  # racing against an eternal crash loop.
  defmodule CrashLooper do
    @moduledoc false
    use GenServer

    @crash_budget 20

    def start_link(counter_ref), do: GenServer.start_link(__MODULE__, counter_ref)

    @impl true
    def init(counter_ref), do: {:ok, counter_ref, {:continue, :schedule}}

    @impl true
    def handle_continue(:schedule, counter_ref) do
      if :counters.get(counter_ref, 1) < @crash_budget do
        :counters.add(counter_ref, 1, 1)
        raise "simulated bad-interval crash"
      else
        {:noreply, counter_ref}
      end
    end
  end

  # Regression for #456: the 16 poller modules used to be flat siblings of Cinder.Repo and
  # CinderWeb.Endpoint directly under Cinder.Supervisor's shared, default restart budget (3
  # restarts / 5 seconds). A crash loop in any one of them — their init/1 -> handle_continue
  # scheduling path is not covered by isolate/2 — could exhaust that shared budget and take the
  # whole application down with it, not just the misbehaving worker.
  #
  # This proves the isolation Cinder.PollerSupervisor now provides: a child that crash-loops past
  # its own 16-restarts-in-5s budget only takes down that nested supervisor (which its parent
  # restarts as a single child, well within the parent's own budget); an unrelated sibling
  # standing in for core infra (Cinder.Repo/CinderWeb.Endpoint) is never touched.
  test "a crash-looping poller exhausts only PollerSupervisor's own budget, never its parent's" do
    :ok = Supervisor.terminate_child(Cinder.Supervisor, Cinder.PollerSupervisor)
    on_exit(fn -> Supervisor.restart_child(Cinder.Supervisor, Cinder.PollerSupervisor) end)

    counter_ref = :counters.new(1, [])

    {:ok, top} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Agent, fn -> :infra end}, id: :infra),
          {Cinder.PollerSupervisor, [{CrashLooper, counter_ref}]}
        ],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    infra_pid = child_pid(top, :infra)
    infra_ref = Process.monitor(infra_pid)

    # Let the (bounded) crash loop run to completion: past PollerSupervisor's own budget, through
    # its restart, and settled. Captured: each crash logs an expected GenServer termination report.
    capture_log(fn -> Process.sleep(500) end)

    assert :counters.get(counter_ref, 1) == 20
    assert Process.alive?(top)
    assert Process.alive?(infra_pid)
    refute_received {:DOWN, ^infra_ref, :process, ^infra_pid, _reason}
  end

  defp child_pid(supervisor, id) do
    {_id, pid, _type, _modules} =
      supervisor |> Supervisor.which_children() |> Enum.find(&match?({^id, _, _, _}, &1))

    pid
  end
end
