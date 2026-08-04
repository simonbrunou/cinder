defmodule Cinder.DiskTest do
  # async: false — configured_roots/0 and check_all/0 tests mutate global Application env
  # (:movies_library_path / :tv_library_path), same reasoning as CinderWeb.SettingsLiveTest.
  use ExUnit.Case, async: false

  alias Cinder.Disk

  describe "stats/1" do
    @tag :tmp_dir
    test "reads real free/total bytes via bounded df", %{tmp_dir: tmp} do
      assert {:ok, %{free_bytes: free, total_bytes: total}} = Disk.stats(tmp)
      assert free >= 0
      assert total > 0
      assert free <= total
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
      saved =
        Map.new([:disk_probe_timeout, :disk_df_bin], fn key ->
          {key, Application.get_env(:cinder, key)}
        end)

      on_exit(fn ->
        Enum.each(saved, fn
          {key, nil} -> Application.delete_env(:cinder, key)
          {key, value} -> Application.put_env(:cinder, key, value)
        end)
      end)

      hanging_df = Path.join(tmp, "hanging-df")
      pid_file = Path.join(tmp, "hanging-df.pid")

      File.write!(
        hanging_df,
        "#!/bin/sh\nprintf '%s' \"$$\" > '#{pid_file}'\nexec sleep 10\n"
      )

      File.chmod!(hanging_df, 0o755)
      Application.put_env(:cinder, :disk_df_bin, hanging_df)
      Application.put_env(:cinder, :disk_probe_timeout, 100)

      assert Disk.stats(tmp) == {:error, :timeout}
      assert File.exists?(pid_file)

      {_output, status} =
        System.cmd(
          "/bin/sh",
          ["-c", ~S|kill -0 "$1"|, "kill", String.trim(File.read!(pid_file))],
          stderr_to_stdout: true
        )

      assert status != 0
    end
  end

  describe "configured_roots/0 and check_all/0" do
    setup do
      saved = %{
        movies_library_path: Application.get_env(:cinder, :movies_library_path),
        tv_library_path: Application.get_env(:cinder, :tv_library_path),
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
        tv_library_path: Application.get_env(:cinder, :tv_library_path)
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
        [:import_roots, :movies_library_path, :tv_library_path, :disk_stats_stub],
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
end
