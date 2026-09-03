defmodule Cinder.PollerSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Mirrors the real defect's exact shape AND its real trigger: init/1 succeeds (so the
  # supervisor's own start_link never fails outright), then the handle_continue(:schedule, ...)
  # path that PollerSkeleton runs immediately after every (re)start raises, on EVERY restart, with
  # no settling — a persistently bad `interval` value (e.g. non-integer or negative) reaching
  # Process.send_after/3 never clears itself, unlike a transient blip.
  defmodule PermanentCrashLooper do
    @moduledoc false
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

    @impl true
    def init(_opts), do: {:ok, %{}, {:continue, :schedule}}

    @impl true
    def handle_continue(:schedule, _state), do: raise("permanently bad interval")
  end

  # Regression for #456, verified empirically first: booting a real Cinder.Download.Poller with a
  # permanently invalid `interval` (before this fix) took Cinder.Repo and CinderWeb.Endpoint down
  # a few seconds later — `MIX_ENV=dev mix run -e` against the real app, `:start_poller` on and
  # `config :cinder, Cinder.Download.Poller, interval: -1`, showed `Cinder.Supervisor`, `Repo`,
  # and `Endpoint` all `nil` (dead) after 3s. Nesting the 16 pollers under their own
  # Cinder.PollerSupervisor alone is NOT enough for a *permanently* crash-looping worker (as
  # opposed to a transient burst): the nested supervisor's own 16-restarts-in-5s budget exhausts
  # near-instantly, it terminates, its DEFAULT (:permanent) restart type has Cinder.Supervisor try
  # again, the same static child crashes again immediately post-restart, and three of those
  # near-instant exhaustion cycles fit comfortably inside Cinder.Supervisor's own default
  # 3-restarts-in-5-seconds budget — cascading it down too, taking Repo/Endpoint with it.
  # `restart: :temporary` on Cinder.PollerSupervisor's own child spec (Cinder.Application.start/2)
  # is what actually stops this: the outer supervisor gives up restarting it after the first
  # exhaustion instead of retrying forever.
  #
  # This test drives the REAL, already-running Cinder.PollerSupervisor (not a synthetic stand-in)
  # to exactly that exhaustion, and asserts the real Cinder.Repo, CinderWeb.Endpoint, and
  # Cinder.Supervisor are all still the same pids afterward.
  test "a permanently crash-looping poller exhausts only the real Cinder.PollerSupervisor, never Cinder.Repo, CinderWeb.Endpoint, or Cinder.Supervisor" do
    repo_pid = Process.whereis(Cinder.Repo)
    endpoint_pid = Process.whereis(CinderWeb.Endpoint)
    supervisor_pid = Process.whereis(Cinder.Supervisor)
    assert is_pid(repo_pid) and is_pid(endpoint_pid) and is_pid(supervisor_pid)

    on_exit(fn ->
      if is_nil(Process.whereis(Cinder.PollerSupervisor)) do
        Supervisor.start_child(
          Cinder.Supervisor,
          Supervisor.child_spec({Cinder.PollerSupervisor, Cinder.Application.poller_child()},
            restart: :temporary
          )
        )
      end
    end)

    capture_log(fn ->
      {:ok, _pid} = Supervisor.start_child(Cinder.PollerSupervisor, PermanentCrashLooper)
      # Long enough for PollerSupervisor's own budget (16 restarts / 5s, near-instant crashes) to
      # exhaust and for it to terminate for good.
      Process.sleep(500)
    end)

    assert Process.whereis(Cinder.Repo) == repo_pid
    assert Process.whereis(CinderWeb.Endpoint) == endpoint_pid
    assert Process.whereis(Cinder.Supervisor) == supervisor_pid
    assert is_nil(Process.whereis(Cinder.PollerSupervisor))
  end

  # The negative control the test above is meaningless without: the exact same permanent crash
  # loop, nested under a supervisor left at OTP's default (:permanent) restart type instead of
  # :temporary, DOES cascade past its own parent — proving `restart: :temporary` is load-bearing,
  # not incidental, and guarding against it silently regressing back to a plain (but still
  # :permanent) nested supervisor. Synthetic (not the real Cinder.Supervisor): it needs a
  # deliberately tiny (3/5) parent budget to observe the cascade in bounded time.
  test "without :temporary, the same permanent crash loop cascades past its parent supervisor" do
    :ok = Supervisor.terminate_child(Cinder.Supervisor, Cinder.PollerSupervisor)

    on_exit(fn ->
      Supervisor.start_child(
        Cinder.Supervisor,
        Supervisor.child_spec({Cinder.PollerSupervisor, Cinder.Application.poller_child()},
          restart: :temporary
        )
      )
    end)

    # Supervisor.start_link/2 links the caller to `top`; without trapping exits, `top`'s own exit
    # (once ITS supervisor exceeds max_restarts) would kill this test process too, before it could
    # observe anything.
    Process.flag(:trap_exit, true)

    {:ok, top} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Agent, fn -> :infra end}, id: :infra),
          Supervisor.child_spec({Cinder.PollerSupervisor, [PermanentCrashLooper]}, id: :pollers)
        ],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      )

    capture_log(fn -> Process.sleep(500) end)
    assert_receive {:EXIT, ^top, _reason}, 1_000
    refute Process.alive?(top)
  end
end
