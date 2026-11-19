defmodule Cinder.DiskTest do
  # async: false — configured_roots/0 and check_all/0 tests mutate global Application env
  # (:movies_library_path / :tv_library_path), same reasoning as CinderWeb.SettingsLiveTest.
  use ExUnit.Case, async: false

  import Cinder.PollerHelpers, only: [poll_until: 2]

  alias Cinder.ConfigCase
  alias Cinder.Disk
  alias Cinder.Test.OsProcess

  describe "stats/1" do
    @tag :tmp_dir
    test "reads real free/total bytes via bounded df", %{tmp_dir: tmp} do
      assert {:ok, %{free_bytes: free, total_bytes: total}} = Disk.stats(tmp)
      assert free >= 0
      assert total > 0
      assert free <= total
    end

    @tag :tmp_dir
    test "treats a relative path beginning with a dash as a df operand", %{tmp_dir: tmp} do
      File.cd!(tmp, fn ->
        File.mkdir!("-library")

        assert {:ok, %{free_bytes: free, total_bytes: total}} = Disk.stats("-library")
        assert free >= 0
        assert total > 0
      end)
    end

    # Locks the 1024-byte unit contract of the POSIX `df -kP` parser.
    @tag :tmp_dir
    test "reports the same total bytes as df -kP", %{tmp_dir: tmp} do
      assert {:ok, %{total_bytes: total}} = Disk.stats(tmp)

      {df_output, 0} = System.cmd("df", ["-kP", tmp])
      [_header, data | _rest] = String.split(df_output, "\n", trim: true)
      [_filesystem, df_total_kb | _rest] = String.split(data)

      assert total == String.to_integer(df_total_kb) * 1024
    end

    test "returns {:error, :enoent} for a path that isn't a directory" do
      path = "/nonexistent/cinder-disk-test-#{System.unique_integer([:positive])}"
      refute File.dir?(path)

      assert {:error, :enoent} = Disk.stats(path)
    end

    @tag :tmp_dir
    test "returns a timeout error when the df probe stops responding", %{tmp_dir: tmp} do
      pid_file = Path.join(tmp, "hanging-df.pid")
      on_exit(fn -> kill_recorded_pids(pid_file) end)

      ConfigCase.put_env(
        disk_df_bin: write_pid_recording_stub(tmp, "hanging-df", pid_file),
        disk_probe_timeout: 100
      )

      assert Disk.stats(tmp) == {:error, :timeout}
      assert_dead_if_recorded(pid_file)
    end

    @tag :tmp_dir
    test "bounds directory validation inside the probe subprocess", %{tmp_dir: tmp} do
      pid_file = Path.join(tmp, "hanging-shell.pid")
      on_exit(fn -> kill_recorded_pids(pid_file) end)

      ConfigCase.put_env(
        disk_probe_shell: write_pid_recording_stub(tmp, "hanging-shell", pid_file),
        disk_probe_timeout: 100
      )

      assert Disk.stats(tmp) == {:error, :timeout}
      assert_dead_if_recorded(pid_file)
    end

    @tag :tmp_dir
    test "rejects concurrent probes instead of queueing deadlines", %{tmp_dir: tmp} do
      pid_file = Path.join(tmp, "busy-df.pid")
      on_exit(fn -> kill_recorded_pids(pid_file) end)

      # The first probe must still be running when the second arrives, so it gets a deadline a
      # loaded runner cannot miss before its stub records: a shorter one can kill the stub before
      # it writes its pid (#1489). The test then ends that probe by killing its stub.
      ConfigCase.put_env(
        disk_df_bin: write_pid_recording_stub(tmp, "busy-df", pid_file),
        disk_probe_timeout: 10_000
      )

      first_probe = Task.async(fn -> Disk.stats(tmp) end)
      poll_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(pid_file)) end, timeout: 10_000)

      assert_refused_at_once(tmp, {:error, :probe_busy})

      kill_recorded_pids(pid_file)
      assert Task.await(first_probe) == {:error, {:df_exit, 137}}
    end

    @tag :tmp_dir
    test "rejects new probes while a timed-out process is still draining", %{tmp_dir: tmp} do
      hanging_df = Path.join(tmp, "unkillable-df")
      pid_file = Path.join(tmp, "unkillable-df.pids")
      invocation_file = Path.join(tmp, "unkillable-df.invocations")

      File.write!(
        hanging_df,
        "#!/bin/sh\nprintf '%s\\n' \"$$\" >> '#{pid_file}'\nprintf x >> '#{invocation_file}'\nexec sleep 10\n"
      )

      File.chmod!(hanging_df, 0o755)
      on_exit(fn -> kill_recorded_pids(pid_file) end)

      ConfigCase.put_env(
        disk_df_bin: hanging_df,
        disk_probe_timeout: 100,
        disk_probe_killer: fn _pid -> :ok end
      )

      assert Disk.stats(tmp) == {:error, :timeout}
      assert_refused_at_once(tmp, {:error, :probe_draining})

      # The killer above leaves the stub alive, so it records once it starts, within this 10 s
      # poll. The pid line comes first, so `kill_recorded_pids/1` below finds it.
      poll_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(invocation_file)) end,
        timeout: 10_000
      )

      assert File.read!(invocation_file) == "x"

      kill_recorded_pids(pid_file)
      # The recovered probe runs the real `df` and killer, the defaults `Cinder.Disk.CommandProbe`
      # reads, and is meant to finish, so it keeps the 10 s deadline `assert_refused_at_once/2`
      # set, one a loaded runner cannot miss (docs/agents/testing.md).
      Application.delete_env(:cinder, :disk_df_bin)
      Application.delete_env(:cinder, :disk_probe_killer)

      poll_until(fn -> match?({:ok, _stats}, Disk.stats(tmp)) end, timeout: 10_000)
    end

    # #976: a probe timeout kills the probe's whole process group, as `BoundedCommand` does, so a
    # process the fake `df` forked dies with it. A non-interactive shell has no job control, so
    # the child stays in the probe's group. The child records its own pid, so a kill that missed
    # it leaves it alive to record even when the kill lands before the fake `df` gets further; a
    # child the kill reached before it recorded leaves no record, and the test passes it. The child
    # then sleeps 10 s, well past the 500 ms timeout, the 100 ms reap wait and the waits of
    # `OsProcess.await_record/1` and `OsProcess.dead?/1` on an idle host.
    @tag :tmp_dir
    test "kills what the df probe forked when it times out", %{tmp_dir: tmp} do
      child_pid_file = Path.join(tmp, "forking-df.child")
      probe_pid_file = Path.join(tmp, "forking-df.pid")

      forking_df =
        write_fake_df(tmp, "forking-df", """
        /bin/sh -c 'echo $$ > "$1.tmp" && mv "$1.tmp" "$1" && exec sleep 10' child '#{child_pid_file}' &
        echo $$ > '#{probe_pid_file}.tmp' && mv '#{probe_pid_file}.tmp' '#{probe_pid_file}'
        exec sleep 30
        """)

      on_exit(fn ->
        kill_recorded_pids(child_pid_file)
        kill_recorded_pids(probe_pid_file)
      end)

      ConfigCase.put_env(disk_df_bin: forking_df, disk_probe_timeout: 500)

      assert Disk.stats(tmp) == {:error, :timeout}
      assert_dead_if_recorded(child_pid_file)
    end

    @tag :tmp_dir
    test "parses a POSIX row whose filesystem and mountpoint contain spaces", %{tmp_dir: tmp} do
      df =
        write_fake_df(
          tmp,
          "spaced-df",
          "printf '%s\\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' " <>
            "'/dev/with 123 1000 250 750 25% /mnt/with space'"
        )

      ConfigCase.put_env(:disk_df_bin, df)

      assert Disk.stats(tmp) ==
               {:ok, %{free_bytes: 750 * 1024, total_bytes: 1_000 * 1024}}
    end

    @tag :tmp_dir
    test "clamps negative available blocks to zero", %{tmp_dir: tmp} do
      df =
        write_fake_df(
          tmp,
          "negative-free-df",
          "printf '%s\\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' " <>
            "'/dev/disk 1000 1100 -100 110% /mnt'"
        )

      ConfigCase.put_env(:disk_df_bin, df)

      assert Disk.stats(tmp) == {:ok, %{free_bytes: 0, total_bytes: 1_000 * 1024}}
    end

    @tag :tmp_dir
    test "returns unreadable for malformed df output", %{tmp_dir: tmp} do
      ConfigCase.put_env(
        :disk_df_bin,
        write_fake_df(tmp, "malformed-df", "printf '%s\\n' 'not df output'")
      )

      assert Disk.stats(tmp) == {:error, :unreadable}
    end

    @tag :tmp_dir
    test "returns the df exit status", %{tmp_dir: tmp} do
      ConfigCase.put_env(:disk_df_bin, write_fake_df(tmp, "failed-df", "exit 42"))

      assert Disk.stats(tmp) == {:error, {:df_exit, 42}}
    end
  end

  describe "configured_roots/0 and check_all/0" do
    setup do
      saved = %{
        movies_library_path: Application.get_env(:cinder, :movies_library_path),
        movies_anime_library_path: Application.get_env(:cinder, :movies_anime_library_path),
        tv_library_path: Application.get_env(:cinder, :tv_library_path),
        tv_anime_library_path: Application.get_env(:cinder, :tv_anime_library_path),
        disk_stats_stub: Application.get_env(:cinder, :disk_stats_stub)
      }

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> Application.delete_env(:cinder, k)
          {k, v} -> Application.put_env(:cinder, k, v)
        end)
      end)

      :ok
    end

    @tag :tmp_dir
    test "includes every configured root and skips a blank one", %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.put_env(:cinder, :tv_library_path, "")

      assert Disk.configured_roots() == [{:movies, tmp}]
    end

    test "includes distinct Anime destinations and omits a duplicate fallback" do
      Application.put_env(:cinder, :movies_library_path, "/movies")
      Application.put_env(:cinder, :movies_anime_library_path, "/anime-movies")
      Application.put_env(:cinder, :tv_library_path, "/tv")
      Application.put_env(:cinder, :tv_anime_library_path, "/tv")

      assert Disk.configured_roots() == [
               {:movies, "/movies"},
               {:anime_movies, "/anime-movies"},
               {:tv, "/tv"}
             ]
    end

    test "skips an entirely unset root" do
      Application.delete_env(:cinder, :movies_library_path)
      Application.delete_env(:cinder, :tv_library_path)

      assert Disk.configured_roots() == []
    end

    @tag :tmp_dir
    test "check_all/0 reads stats for a configured root", %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.delete_env(:cinder, :tv_library_path)

      rows = Disk.check_all()

      assert %{kind: :movies, path: ^tmp, status: {:ok, %{free_bytes: _, total_bytes: _}}} =
               Enum.find(rows, &(&1.kind == :movies))
    end

    @tag :tmp_dir
    test "check_all/0 uses the configured prober", %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.delete_env(:cinder, :tv_library_path)
      Application.put_env(:cinder, :disk_stats_stub, {:error, :probe_timeout})

      assert %{kind: :movies, path: ^tmp, status: {:error, :probe_timeout}} =
               Enum.find(Disk.check_all(), &(&1.kind == :movies))
    end

    test "check_all/0 degrades gracefully for a configured but nonexistent root" do
      path = "/nonexistent/cinder-disk-test-#{System.unique_integer([:positive])}"
      Application.put_env(:cinder, :movies_library_path, path)
      Application.delete_env(:cinder, :tv_library_path)

      Application.put_env(:cinder, :disk_stats_stub, fn
        ^path -> {:error, :enoent}
        _other -> {:ok, %{free_bytes: 1_000, total_bytes: 2_000}}
      end)

      rows = Disk.check_all()

      assert %{kind: :movies, path: ^path, status: {:error, :enoent}} =
               Enum.find(rows, &(&1.kind == :movies))
    end

    @tag :tmp_dir
    test "check_all/0 always includes a :database row for the DB volume", %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.delete_env(:cinder, :tv_library_path)

      assert %{kind: :database, path: db_path, status: {:ok, %{free_bytes: _}}} =
               Enum.find(Disk.check_all(), &(&1.kind == :database))

      assert db_path == Disk.db_root()
    end
  end

  describe "db_root/0 and monitored_roots/0" do
    setup do
      saved = %{
        movies_library_path: Application.get_env(:cinder, :movies_library_path),
        movies_anime_library_path: Application.get_env(:cinder, :movies_anime_library_path),
        tv_library_path: Application.get_env(:cinder, :tv_library_path),
        tv_anime_library_path: Application.get_env(:cinder, :tv_anime_library_path)
      }

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> Application.delete_env(:cinder, k)
          {k, v} -> Application.put_env(:cinder, k, v)
        end)
      end)

      :ok
    end

    test "db_root/0 is the directory holding the configured database file" do
      db = Application.get_env(:cinder, Cinder.Repo)[:database]
      assert Disk.db_root() == Path.dirname(db)
    end

    @tag :tmp_dir
    test "monitored_roots/0 appends the database volume after the library roots", %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.delete_env(:cinder, :tv_library_path)

      assert Disk.monitored_roots() == [{:movies, tmp}, {:database, Disk.db_root()}]
    end

    test "monitored_roots/0 is just the database volume when no library root is configured" do
      Application.delete_env(:cinder, :movies_library_path)
      Application.delete_env(:cinder, :tv_library_path)

      assert Disk.monitored_roots() == [{:database, Disk.db_root()}]
    end
  end

  # db_free_bytes/0 reads the DB volume through the :disk_prober seam (StubDisk in test), so it
  # never probes a real disk — this is what /healthz uses for its fast, DB-free floor check.
  describe "db_free_bytes/0" do
    setup :restore_disk_env

    test "returns the free bytes reported by the prober for the DB volume" do
      Application.put_env(
        :cinder,
        :disk_stats_stub,
        {:ok, %{free_bytes: 42_000, total_bytes: 100_000}}
      )

      assert Disk.db_free_bytes() == {:ok, 42_000}
    end

    test "propagates a prober error so the caller fails open" do
      Application.put_env(:cinder, :disk_stats_stub, {:error, :df_failed})
      assert Disk.db_free_bytes() == {:error, :df_failed}
    end
  end

  # The guards read free space through the :disk_prober seam (Cinder.Test.StubDisk in test), driven
  # per-case by :disk_stats_stub — so these never probe a real disk.
  describe "grab_space_available?/1" do
    setup :restore_disk_env

    @eight_gb 8_000_000_000

    test "true for an unknown release size (nothing to guard)" do
      Application.put_env(:cinder, :disk_stats_stub, {:ok, %{free_bytes: 0, total_bytes: 100}})
      assert Disk.grab_space_available?(nil)
      assert Disk.grab_space_available?(0)
    end

    test "true when no download root is configured (fails open)" do
      Application.put_env(:cinder, :import_roots, [])
      Application.put_env(:cinder, :disk_stats_stub, {:ok, %{free_bytes: 0, total_bytes: 100}})
      assert Disk.grab_space_available?(@eight_gb)
    end

    test "true when a root has room for the release plus the margin" do
      Application.put_env(:cinder, :import_roots, ["/downloads"])

      Application.put_env(
        :cinder,
        :disk_stats_stub,
        {:ok, %{free_bytes: 100_000_000_000, total_bytes: 200_000_000_000}}
      )

      assert Disk.grab_space_available?(@eight_gb)
    end

    test "false when every readable root positively lacks room" do
      Application.put_env(:cinder, :import_roots, ["/downloads"])

      Application.put_env(
        :cinder,
        :disk_stats_stub,
        {:ok, %{free_bytes: 1_000_000_000, total_bytes: 100_000_000_000}}
      )

      refute Disk.grab_space_available?(@eight_gb)
    end

    test "true when a root's free space can't be read (fails open)" do
      Application.put_env(:cinder, :import_roots, ["/downloads"])
      Application.put_env(:cinder, :disk_stats_stub, {:error, :df_failed})
      assert Disk.grab_space_available?(@eight_gb)
    end

    test "true when at least one of several roots has room" do
      Application.put_env(:cinder, :import_roots, ["/full", "/empty"])

      Application.put_env(:cinder, :disk_stats_stub, fn
        "/full" -> {:ok, %{free_bytes: 1_000_000_000, total_bytes: 100_000_000_000}}
        "/empty" -> {:ok, %{free_bytes: 100_000_000_000, total_bytes: 200_000_000_000}}
      end)

      assert Disk.grab_space_available?(@eight_gb)
    end
  end

  describe "import_space_available?/1" do
    setup :restore_disk_env

    test "true when the kind's library root is unconfigured (the importer already holds)" do
      Application.delete_env(:cinder, :movies_library_path)
      assert Disk.import_space_available?(:movies)
    end

    test "false when the configured library root is below the floor" do
      Application.put_env(:cinder, :movies_library_path, "/library")

      Application.put_env(
        :cinder,
        :disk_stats_stub,
        {:ok, %{free_bytes: 500_000_000, total_bytes: 100_000_000_000}}
      )

      refute Disk.import_space_available?(:movies)
    end

    test "checks the Anime destination for an Anime title" do
      Application.put_env(:cinder, :movies_library_path, "/library")
      Application.put_env(:cinder, :movies_anime_library_path, "/anime")

      Application.put_env(:cinder, :disk_stats_stub, fn
        "/library" -> {:ok, %{free_bytes: 50_000_000_000, total_bytes: 100_000_000_000}}
        "/anime" -> {:ok, %{free_bytes: 500_000_000, total_bytes: 100_000_000_000}}
      end)

      refute Disk.import_space_available?(:movies, %{media_profile: :anime})
      assert Disk.import_space_available?(:movies, %{media_profile: :standard})
    end

    test "true when the configured library root has ample free space" do
      Application.put_env(:cinder, :tv_library_path, "/tv")

      Application.put_env(
        :cinder,
        :disk_stats_stub,
        {:ok, %{free_bytes: 50_000_000_000, total_bytes: 100_000_000_000}}
      )

      assert Disk.import_space_available?(:tv)
    end

    test "true when the root's free space can't be read (fails open)" do
      Application.put_env(:cinder, :movies_library_path, "/library")
      Application.put_env(:cinder, :disk_stats_stub, {:error, :enoent})
      assert Disk.import_space_available?(:movies)
    end
  end

  defp restore_disk_env(_context) do
    saved =
      Map.new(
        [
          :import_roots,
          :movies_library_path,
          :movies_anime_library_path,
          :tv_library_path,
          :tv_anime_library_path,
          :disk_stats_stub
        ],
        &{&1, Application.get_env(:cinder, &1)}
      )

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:cinder, k)
        {k, v} -> Application.put_env(:cinder, k, v)
      end)
    end)

    :ok
  end

  defp write_fake_df(tmp, name, body) do
    path = Path.join(tmp, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  # A stub that writes its pid to `pid_file` first, then hangs, for a fake `df` or probe shell.
  defp write_pid_recording_stub(tmp, name, pid_file),
    do: write_fake_df(tmp, name, "printf '%s' \"$$\" > '#{pid_file}'\nexec sleep 10")

  # A refusal the probe owner answers from its state, run under a 10 s deadline so a slow
  # runner cannot turn it into a timeout, with an elapsed bound well under that deadline, not a
  # guess at runner lag (docs/agents/testing.md, docs/agents/ci.md "Wall-clock tests").
  defp assert_refused_at_once(tmp, refusal) do
    ConfigCase.put_env(:disk_probe_timeout, 10_000)
    started = System.monotonic_time(:millisecond)

    assert Disk.stats(tmp) == refusal
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  defp kill_recorded_pids(pid_file) do
    if File.exists?(pid_file) do
      pid_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn pid ->
        System.cmd("/bin/sh", ["-c", ~S(kill -KILL "$1" 2>/dev/null || true), "kill", pid])
      end)
    end
  end

  # A loaded runner can start the fake `df` or shell past the probe's deadline, so the kill can
  # land before the stub writes its pid file (#1489), and a missing record passes. A stub the
  # timeout left alive writes it once it starts. When that record appears within
  # `OsProcess.await_record/1`'s wait, `OsProcess.dead?/1` fails on the live process.
  defp assert_dead_if_recorded(pid_file) do
    case OsProcess.await_record(pid_file) do
      {:ok, pid} -> assert OsProcess.dead?(pid |> String.trim() |> String.to_integer())
      :none -> :ok
    end
  end
end
