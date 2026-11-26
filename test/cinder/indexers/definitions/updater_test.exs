defmodule Cinder.Indexers.Definitions.UpdaterTest do
  # The worker's runs reach the source mock and the sandbox from its own task, so the mock is
  # global and the module is not async. Every definition is written for Cinder
  # (`Cinder.DefinitionFixtures`), and the load verdicts come from its `check/1`.
  use Cinder.DataCase, async: false

  import Cinder.DefinitionFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Archive, Loader, LoadResult, SourceMock, StoredSet}
  alias Cinder.Indexers.Definitions.{Updater, UpdateRun}
  alias Cinder.Test.DefinitionsZip

  # Failed and refused runs log warnings; keep them out of the suite's output.
  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    :persistent_term.erase({Updater, :status})
    on_exit(fn -> :persistent_term.erase({Updater, :status}) end)
    :ok = Updater.subscribe()
    :ok
  end

  @commit_a String.duplicate("a", 40)
  @commit_b String.duplicate("b", 40)
  @t0 ~U[2026-11-20 08:00:00Z]

  defp fillers, do: for(i <- 1..100, do: {"filler-#{i}.yml", definition("filler-#{i}")})

  defp zip(commit, files) do
    DefinitionsZip.codeload(commit, [
      {"VERSIONS", "MIN_VERSION=11\nMAX_VERSION=12\n"}
      | for({name, bytes} <- files, do: {"definitions/v11/" <> name, bytes})
    ])
  end

  # Upstream's master names `commit`, whose zip holds the fillers and `files`. Each source call
  # is reported to the test.
  defp upstream(commit, files \\ [{"tracker.yml", definition()}]) do
    test_pid = self()
    zip = zip(commit, fillers() ++ files)

    stub(SourceMock, :master_commit, fn ->
      send(test_pid, :master_commit)
      {:ok, commit}
    end)

    stub(SourceMock, :download, fn ^commit ->
      send(test_pid, {:download, commit})
      {:ok, zip}
    end)
  end

  # Every master_commit call fails with `tag`, reported to the test.
  defp upstream_fails(tag) do
    test_pid = self()

    stub(SourceMock, :master_commit, fn ->
      send(test_pid, :master_commit)
      {:error, tag}
    end)
  end

  # A clock the test moves.
  defp clock!(at) do
    {:ok, clock} = Agent.start_link(fn -> at end)
    clock
  end

  defp set_clock(clock, at), do: Agent.update(clock, fn _at -> at end)

  # Starts the worker with the test's check and clock. Each timer it arms reaches the test as
  # `{:armed, delay_ms, message}`, and the test fires it by sending the message.
  defp start_updater(opts \\ []) do
    test_pid = self()
    clock = Keyword.get(opts, :clock, clock!(@t0))

    start_supervised!(
      {Updater,
       [
         check: Keyword.get(opts, :check, &check/1),
         clock: fn -> Agent.get(clock, & &1) end,
         schedule:
           Keyword.get(opts, :schedule, fn delay, message ->
             send(test_pid, {:armed, delay, message})
             make_ref()
           end)
       ]}
    )
  end

  defp await_run do
    assert_receive {:definitions_update, outcome}, 10_000
    outcome
  end

  defp armed do
    assert_receive {:armed, delay, message}, 10_000
    {delay, message}
  end

  defp run_row, do: Repo.get!(UpdateRun, UpdateRun.id())

  describe "a run" do
    test "the boot run applies a new set, records the success and arms 24 hours" do
      upstream(@commit_a)
      start_updater()

      assert await_run() == :applied
      assert {86_400_000, _message} = armed()
      assert_received {:download, @commit_a}
      assert {:loaded, %{commit: @commit_a, count: 101}} = Definitions.set_state(@t0)

      assert %UpdateRun{
               started_at: @t0,
               ended_at: @t0,
               outcome: :applied,
               commit: @commit_a,
               error: nil,
               last_success_at: @t0,
               first_failure_at: nil
             } = run_row()

      assert %{module: Updater, last_run_at: @t0, interval: 86_400_000} = Updater.status()
    end

    test "an unchanged commit is a success that downloads nothing" do
      mirror_at(@commit_a)
      test_pid = self()

      expect(SourceMock, :master_commit, fn ->
        send(test_pid, :master_commit)
        {:ok, @commit_a}
      end)

      expect(SourceMock, :download, 0, fn _commit -> {:ok, ""} end)
      start_updater()

      assert await_run() == :unchanged
      assert {86_400_000, _message} = armed()
      assert_received :master_commit
      assert %UpdateRun{outcome: :unchanged, commit: @commit_a, last_success_at: @t0} = run_row()
    end

    test "a new commit downloads once" do
      mirror_at(@commit_a)
      test_pid = self()
      zip = zip(@commit_b, fillers() ++ [{"tracker.yml", definition()}])
      expect(SourceMock, :master_commit, fn -> {:ok, @commit_b} end)

      expect(SourceMock, :download, 1, fn @commit_b ->
        send(test_pid, :download)
        {:ok, zip}
      end)

      start_updater()

      assert await_run() == :applied
      assert_received :download
      assert %UpdateRun{outcome: :applied, commit: @commit_b} = run_row()
    end

    test "a refused answer is recorded by its state and is a failure" do
      upstream(@commit_a, [])
      start_updater()

      # 100 fillers with no tracker pass the floor; take 20 away for a second answer.
      assert await_run() == :applied
      {_delay, message} = armed()

      small = for i <- 1..80, do: {"filler-#{i}.yml", definition("filler-#{i}")}
      zip = zip(@commit_b, small)
      stub(SourceMock, :master_commit, fn -> {:ok, @commit_b} end)
      stub(SourceMock, :download, fn @commit_b -> {:ok, zip} end)
      send(Updater, message)

      assert await_run() == :shrank
      assert %UpdateRun{outcome: :shrank, commit: @commit_b, error: nil} = run_row()
      assert run_row().first_failure_at == @t0
      # A set is loaded: the failure waits 24 hours.
      assert {86_400_000, _message} = armed()
    end

    test "a run after a refusal asks with the loaded commit and downloads again" do
      upstream(@commit_a, [])
      start_updater()
      assert await_run() == :applied
      {_delay, message} = armed()

      small = for i <- 1..80, do: {"filler-#{i}.yml", definition("filler-#{i}")}
      zip = zip(@commit_b, small)
      test_pid = self()
      stub(SourceMock, :master_commit, fn -> {:ok, @commit_b} end)

      stub(SourceMock, :download, fn @commit_b ->
        send(test_pid, :download)
        {:ok, zip}
      end)

      send(Updater, message)
      assert await_run() == :shrank
      assert_received :download
      {_delay, message} = armed()

      send(Updater, message)
      assert await_run() == :shrank
      assert_received :download
    end

    test "a fetch error records its tag and the first failure, which a later failure keeps" do
      clock = clock!(@t0)
      upstream_fails({:http_status, 503})
      start_updater(clock: clock)

      assert await_run() == {:failed, {:http_status, 503}}
      {_delay, message} = armed()

      assert %UpdateRun{
               outcome: :failed,
               commit: nil,
               first_failure_at: @t0,
               last_success_at: nil
             } =
               row = run_row()

      assert :erlang.binary_to_term(row.error) == {:http_status, 503}
      assert Definitions.set_state(@t0) == {:never_loaded, %{error: {:http_status, 503}}}

      later = DateTime.add(@t0, 60, :second)
      set_clock(clock, later)
      upstream_fails(:timeout)
      send(Updater, message)

      assert await_run() == {:failed, :timeout}
      {_delay, message} = armed()
      assert %UpdateRun{ended_at: ^later, first_failure_at: @t0} = run_row()
      assert Definitions.set_state(later) == {:never_loaded, %{error: :timeout}}

      done = DateTime.add(@t0, 120, :second)
      set_clock(clock, done)
      upstream(@commit_a)
      send(Updater, message)

      assert await_run() == :applied
      {_delay, message} = armed()
      assert %UpdateRun{first_failure_at: nil, last_success_at: ^done, error: nil} = run_row()

      # A failure after the success keeps the success's time. The source call moves the clock,
      # so the run's start and end differ.
      again = DateTime.add(@t0, 180, :second)
      set_clock(clock, again)
      ended = DateTime.add(@t0, 190, :second)

      stub(SourceMock, :master_commit, fn ->
        set_clock(clock, ended)
        {:error, :transport}
      end)

      send(Updater, message)
      assert await_run() == {:failed, :transport}

      assert %UpdateRun{
               started_at: ^again,
               ended_at: ^ended,
               first_failure_at: ^ended,
               last_success_at: ^done
             } = run_row()
    end

    test "a success whose run row fails to write still waits 24 hours" do
      upstream(@commit_a)

      Repo.query!("""
      CREATE TEMP TRIGGER fail_run_row BEFORE INSERT ON definitions_update_run
      BEGIN SELECT RAISE(ABORT, 'run row refused'); END
      """)

      start_updater()

      assert await_run() == :applied
      assert {86_400_000, _message} = armed()
      assert Repo.get(UpdateRun, UpdateRun.id()) == nil
    end
  end

  # The load check, reporting each call to the test, with `fails` failing to load.
  defp counting_check(fails \\ []) do
    test_pid = self()

    fn bytes ->
      send(test_pid, {:checked, bytes})
      if bytes in fails, do: {:error, :not_utf8}, else: check(bytes)
    end
  end

  # Moves the stored load results of `bytes` to an older loader revision.
  defp age_result(bytes) do
    %{revision: revision} = Loader.fingerprint()
    sha = blob_sha(bytes)

    {1, _} =
      Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^sha),
        set: [revision: revision - 1]
      )
  end

  # The checks and the first source call the worker reported, in order, up to that call.
  defp events_to_source_call do
    receive do
      {:checked, bytes} -> [{:checked, bytes} | events_to_source_call()]
      :master_commit -> [:master_commit]
    after
      10_000 -> flunk("no source call")
    end
  end

  describe "the boot re-check" do
    test "checks again only the copies an older fingerprint checked, before any source call" do
      mirror!(definition())
      for name <- ["filler-1", "filler-2"], do: age_result(definition(name))
      upstream_fails(:timeout)

      capture_log(fn ->
        start_updater(check: counting_check())
        await_run()
      end)

      events = events_to_source_call()

      assert List.last(events) == :master_commit

      assert Enum.sort(for {:checked, bytes} <- events, do: bytes) ==
               Enum.sort([definition("filler-1"), definition("filler-2")])

      assert Definitions.stale_copies() == []
    end

    test "a running copy that no longer loads reads so, with no source call during the re-check" do
      mirror!(definition())
      indexer = cardigann!(definition())
      age_result(definition())
      test_pid = self()

      # The boot run's source call waits for the test, so the codes read below are the
      # re-check's.
      stub(SourceMock, :master_commit, fn ->
        send(test_pid, :master_commit)
        send(test_pid, {:run, self()})

        receive do
          :release -> {:error, :timeout}
        end
      end)

      start_updater(check: counting_check([definition()]))

      assert events_to_source_call() == [{:checked, definition()}, :master_commit]
      assert Definitions.indexer_codes() == %{indexer.id => {:no_longer_loads, :not_utf8}}
      assert_receive {:run, run}

      capture_log(fn ->
        send(run, :release)
        await_run()
      end)
    end

    test "a held copy that now loads applies at boot" do
      mirror!(definition())
      indexer = cardigann!(definition(), %{"password" => "hunter2"})
      later = definition("tracker-ns")
      mirror!(later)
      assert pin(indexer).hold == {:not_supported, :html_search}
      age_result(later)
      upstream_fails(:timeout)

      # Under the boot re-check, the held copy now loads.
      check = fn
        ^later ->
          {:ok, loaded} = Loader.load(later)
          {:ok, %{loaded | unsupported: []}}

        bytes ->
          check(bytes)
      end

      capture_log(fn ->
        start_updater(check: check)
        await_run()
      end)

      assert pin(indexer) == %{running: blob_sha(later), held: nil, hold: nil}
    end

    test "a load check that raises at boot logs no URL, and the boot run still fetches" do
      mirror!(definition())
      age_result(definition())
      upstream_fails(:timeout)

      log =
        capture_log(fn ->
          start_updater(check: fn _bytes -> raise "boom at https://tracker.invalid/" end)
          assert await_run() == {:failed, :timeout}
        end)

      assert_received :master_commit
      assert log =~ "indexer definition load check raised on blob"
      refute log =~ "https"
      refute log =~ "tracker.invalid"
    end

    test "a load check that exits at boot still lets the boot run fetch" do
      mirror!(definition())
      age_result(definition())
      upstream_fails(:timeout)

      log =
        capture_log(fn ->
          start_updater(check: fn _bytes -> exit(:boom) end)
          assert await_run() == {:failed, :timeout}
        end)

      assert_received :master_commit
      assert log =~ "indexer definition load check raised on blob"
      assert log =~ ": exit"
      refute log =~ "https"
    end

    test "a re-check whose store raises still lets the boot run fetch" do
      mirror!(definition())
      age_result(definition())
      upstream_fails(:timeout)

      Repo.query!("""
      CREATE TEMP TRIGGER fail_results BEFORE INSERT ON indexer_definition_load_results
      BEGIN SELECT RAISE(ABORT, 'results refused'); END
      """)

      log =
        capture_log(fn ->
          start_updater()
          assert await_run() == {:failed, :timeout}
        end)

      assert_received :master_commit
      assert log =~ "indexer definitions update re-check crashed: Exqlite.Error in"
    end
  end

  describe "the schedule" do
    test "with no set loaded, failures wait 1, 5, 15, 30, 60 and 60 minutes" do
      upstream_fails(:timeout)

      delays =
        capture_log_value(fn ->
          start_updater()

          for _run <- 1..6 do
            await_run()
            {delay, message} = armed()
            send(Updater, message)
            delay
          end
        end)

      assert delays == [60_000, 300_000, 900_000, 1_800_000, 3_600_000, 3_600_000]
      await_run()
      assert %{interval: 3_600_000} = Updater.status()
    end

    test "with a set loaded, a failure waits 24 hours" do
      mirror_at(@commit_a)
      upstream_fails(:timeout)

      capture_log(fn ->
        start_updater()
        assert await_run() == {:failed, :timeout}
      end)

      assert {86_400_000, _message} = armed()
      assert %{interval: 86_400_000} = Updater.status()
    end

    test "with a set loaded, a failure whose run row fails to write waits 24 hours" do
      mirror_at(@commit_a)
      upstream_fails(:timeout)

      Repo.query!("""
      CREATE TEMP TRIGGER fail_run_row BEFORE INSERT ON definitions_update_run
      BEGIN SELECT RAISE(ABORT, 'run row refused'); END
      """)

      capture_log(fn ->
        start_updater()
        assert await_run() == {:failed, :timeout}
      end)

      assert {86_400_000, _message} = armed()
      assert Repo.get(UpdateRun, UpdateRun.id()) == nil
    end

    test "a run that cannot read whether a set is loaded waits 1 minute" do
      mirror_at(@commit_a)
      Repo.query!("ALTER TABLE indexer_definition_set RENAME TO indexer_definition_set_gone")

      capture_log(fn ->
        start_updater()
        assert await_run() == {:failed, :crashed}
      end)

      assert {60_000, _message} = armed()
    end

    test "a success after failures waits 24 hours, and the next failure starts the backoff over" do
      upstream_fails(:timeout)

      capture_log(fn ->
        start_updater()
        await_run()
        {60_000, message} = armed()
        send(Updater, message)
        await_run()
        {300_000, message} = armed()

        upstream(@commit_a)
        send(Updater, message)
        assert await_run() == :applied
        assert {86_400_000, _message} = armed()
      end)

      # With the set row gone, a failure takes the backoff, which the success started over.
      Repo.delete_all(StoredSet)
      upstream_fails(:timeout)

      capture_log(fn ->
        {:ok, :started} = Updater.update_now()
        assert await_run() == {:failed, :timeout}
      end)

      assert {60_000, _message} = armed()
    end

    test "the status before any run reads 24 hours" do
      assert %{module: Updater, last_run_at: nil, interval: 86_400_000} = Updater.status()
    end
  end

  defp capture_log_value(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:value, fun.()}) end)
    assert_received {:value, value}
    value
  end

  describe "update_now/1" do
    test "while idle, returns before the run ends, and the run happens" do
      upstream(@commit_a)
      start_updater()
      assert await_run() == :applied
      {_delay, _message} = armed()

      test_pid = self()

      stub(SourceMock, :master_commit, fn ->
        send(test_pid, {:master_commit, self()})

        receive do
          :release -> {:ok, @commit_a}
        end
      end)

      assert Updater.update_now() == {:ok, :started}
      assert_receive {:master_commit, run}, 10_000
      refute_received {:definitions_update, _outcome}

      send(run, :release)
      assert await_run() == :unchanged
    end

    test "during a run, joins it with no second source call" do
      upstream(@commit_a)
      start_updater()
      assert await_run() == :applied
      {_delay, _message} = armed()

      test_pid = self()

      stub(SourceMock, :master_commit, fn ->
        send(test_pid, {:master_commit, self()})

        receive do
          :release -> {:ok, @commit_a}
        end
      end)

      assert Updater.update_now() == {:ok, :started}
      assert_receive {:master_commit, run}, 10_000
      assert Updater.update_now() == {:ok, :joined}
      send(run, :release)

      assert await_run() == :unchanged
      assert {86_400_000, _message} = armed()
      refute_received {:master_commit, _pid}
      refute_received {:definitions_update, _outcome}
    end

    test "while idle, drops the armed run, so the schedule counts from this run's end" do
      upstream(@commit_a)
      start_updater()
      assert await_run() == :applied
      {_delay, stale} = armed()

      assert Updater.update_now() == {:ok, :started}
      assert await_run() == :unchanged
      assert {86_400_000, _message} = armed()
      assert_received :master_commit
      assert_received :master_commit

      # The timer armed before Update now fires: no run starts.
      send(Updater, stale)
      :sys.get_state(Updater)
      refute_received :master_commit
      assert %{run: nil} = :sys.get_state(Updater)
    end

    test "while idle, cancels the armed timer" do
      upstream(@commit_a)
      test_pid = self()

      # Each armed timer is a real one, an hour out, that would message the test.
      start_updater(
        schedule: fn delay, message ->
          timer = Process.send_after(test_pid, {:fired, message}, :timer.hours(1))
          send(test_pid, {:armed, delay, timer})
          timer
        end
      )

      assert await_run() == :applied
      {_delay, timer} = armed()
      assert is_integer(Process.read_timer(timer))

      assert Updater.update_now() == {:ok, :started}
      assert await_run() == :unchanged
      assert Process.read_timer(timer) == false
      {_delay, next} = armed()
      assert is_integer(Process.read_timer(next))
    end

    test "only the boot run re-checks the stored copies" do
      mirror_at(@commit_a)
      age_result(definition("filler-1"))
      upstream(@commit_a)
      start_updater(check: counting_check())

      assert await_run() == :unchanged
      assert_received {:checked, bytes}
      assert bytes == definition("filler-1")
      {_delay, _message} = armed()

      # A copy goes stale again: neither Update now nor a timer's run checks it.
      age_result(definition("filler-2"))
      assert Updater.update_now() == {:ok, :started}
      assert await_run() == :unchanged
      {_delay, message} = armed()
      send(Updater, message)
      assert await_run() == :unchanged

      refute_received {:checked, _bytes}
      assert [%{blob_sha: sha}] = Definitions.stale_copies()
      assert sha == blob_sha(definition("filler-2"))
    end

    test "with no worker running, answers not running" do
      assert Updater.update_now() == {:error, :not_running}
    end
  end

  describe "crashes" do
    test "a run that raises is logged by closed tags, recorded, and the next run is armed" do
      stub(SourceMock, :master_commit, fn ->
        raise "fetch of https://github.com/Prowlarr/Indexers.git/info/refs?token=secret failed"
      end)

      log =
        capture_log(fn ->
          pid = start_updater()
          assert await_run() == {:failed, :crashed}
          assert Process.whereis(Updater) == pid
        end)

      assert {60_000, _message} = armed()
      assert %UpdateRun{outcome: :failed} = row = run_row()
      assert :erlang.binary_to_term(row.error) == :crashed
      assert log =~ "indexer definitions update run crashed: RuntimeError in"
      refute log =~ "http"
      refute log =~ "token"
    end

    test "an apply its audit row refuses is recorded as crashed and changes no set" do
      mirror!(definition())
      _public = cardigann!(definition())
      before = Definitions.loaded()

      Repo.query!("""
      CREATE TEMP TRIGGER fail_audit BEFORE INSERT ON admin_audit
      BEGIN SELECT RAISE(ABORT, 'audit refused'); END
      """)

      # The new copy moves the public indexer's base URL, which writes an audit row.
      upstream(@commit_b, [
        {"tracker.yml",
         definition("tracker", %{"links" => ["https://www2.invalid/"], "legacylinks" => [link()]})}
      ])

      start_updater()

      assert await_run() == {:failed, :crashed}
      assert Definitions.loaded() == before
      assert :erlang.binary_to_term(run_row().error) == :crashed
    end

    test "no log line of a failed run holds a URL" do
      upstream_fails({:http_status, 404})

      log =
        capture_log(fn ->
          start_updater()
          await_run()
        end)

      assert log =~ "indexer definitions update failed: {:http_status, 404}"
      refute log =~ "http:"
      refute log =~ "https:"
    end

    test "a run task that is killed is recorded as crashed and the next run is armed" do
      test_pid = self()

      stub(SourceMock, :master_commit, fn ->
        send(test_pid, {:master_commit, self()})
        Process.sleep(:infinity)
      end)

      log =
        capture_log(fn ->
          start_updater()
          assert_receive {:master_commit, run}, 10_000
          Process.exit(run, :kill)
          assert await_run() == {:failed, :crashed}
        end)

      assert {60_000, _message} = armed()
      assert :erlang.binary_to_term(run_row().error) == :crashed
      assert log =~ "indexer definitions update run crashed: exit"
    end

    test "a worker that dies is restarted by its supervisor and runs again" do
      upstream_fails(:timeout)

      capture_log(fn ->
        pid = start_updater()
        await_run()
        assert_received :master_commit
        assert {60_000, _message} = armed()
        Process.exit(pid, :kill)
        assert await_run() == {:failed, :timeout}
        refute Process.whereis(Updater) == pid
      end)

      assert_received :master_commit
      assert {60_000, _message} = armed()
    end
  end

  describe "supervision and listing" do
    test "is supervised only when :start_poller is enabled" do
      Cinder.ConfigCase.put_env(:start_poller, false)
      refute Updater in Cinder.Application.poller_child()

      Cinder.ConfigCase.put_env(:start_poller, true)
      assert Updater in Cinder.Application.poller_child()
    end

    test "Cinder.Jobs lists its status" do
      assert %{module: Updater, last_run_at: nil, interval: 86_400_000} in Cinder.Jobs.statuses()
    end
  end

  # A set applied at `commit`, as a run would have left it.
  defp mirror_at(commit) do
    {:ok, set} = Archive.read(zip(commit, fillers() ++ []), commit)
    assert {:ok, {:loaded, _}} = Definitions.apply_set(set, check: &check/1)
  end
end
