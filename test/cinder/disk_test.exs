defmodule Cinder.DiskTest do
  # async: false — configured_roots/0 and check_all/0 tests mutate global Application env
  # (:movies_library_path / :tv_library_path), same reasoning as CinderWeb.SettingsLiveTest.
  use ExUnit.Case, async: false

  alias Cinder.Disk

  @header "Filesystem     1024-blocks     Used Available Capacity Mounted on"

  describe "stats/2" do
    @tag :tmp_dir
    test "parses free/total bytes from a canned df -kP output", %{tmp_dir: tmp} do
      output = @header <> "\n/dev/sda1        1000000   200000    800000      20% /\n"

      assert {:ok, %{free_bytes: free, total_bytes: total}} =
               Disk.stats(tmp, fn -> {output, 0} end)

      assert total == 1_000_000 * 1024
      assert free == 800_000 * 1024
    end

    @tag :tmp_dir
    test "tolerates a filesystem name column (df -P is one line, no wrapping)", %{tmp_dir: tmp} do
      output =
        @header <> "\n/dev/mapper/vg-root  2000000   500000  1500000      25% /\n"

      expected_free = 1_500_000 * 1024
      expected_total = 2_000_000 * 1024

      assert {:ok, %{free_bytes: ^expected_free, total_bytes: ^expected_total}} =
               Disk.stats(tmp, fn -> {output, 0} end)
    end

    test "returns {:error, :enoent} for a path that isn't a directory" do
      path = "/nonexistent/cinder-disk-test-#{System.unique_integer([:positive])}"
      refute File.dir?(path)

      assert {:error, :enoent} = Disk.stats(path, fn -> flunk("must not shell out") end)
    end

    @tag :tmp_dir
    test "returns {:error, :df_failed} when df exits non-zero", %{tmp_dir: tmp} do
      assert {:error, :df_failed} =
               Disk.stats(tmp, fn -> {"df: cannot access: No such file or directory\n", 1} end)
    end

    @tag :tmp_dir
    test "returns {:error, :unparsable} for output with no data row", %{tmp_dir: tmp} do
      assert {:error, :unparsable} = Disk.stats(tmp, fn -> {@header <> "\n", 0} end)
      assert {:error, :unparsable} = Disk.stats(tmp, fn -> {"garbage, not df output", 0} end)
    end

    @tag :tmp_dir
    test "returns {:error, :unparsable} when the size columns aren't integers", %{tmp_dir: tmp} do
      output = @header <> "\n/dev/sda1 abc def ghi 1% /\n"
      assert {:error, :unparsable} = Disk.stats(tmp, fn -> {output, 0} end)
    end

    @tag :tmp_dir
    test "wraps a raising runner instead of crashing the caller", %{tmp_dir: tmp} do
      assert {:error, %RuntimeError{message: "boom"}} =
               Disk.stats(tmp, fn -> raise "boom" end)
    end

    @tag :tmp_dir
    test "reads real free/total bytes with the default df runner", %{tmp_dir: tmp} do
      assert {:ok, %{free_bytes: free, total_bytes: total}} = Disk.stats(tmp)
      assert free >= 0
      assert total > 0
      assert free <= total
    end
  end

  describe "configured_roots/0 and check_all/0" do
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
    test "check_all/0 reads stats for a configured root and reports the rest as unconfigured",
         %{tmp_dir: tmp} do
      Application.put_env(:cinder, :movies_library_path, tmp)
      Application.delete_env(:cinder, :tv_library_path)

      assert [%{kind: :movies, path: ^tmp, status: {:ok, %{free_bytes: _, total_bytes: _}}}] =
               Disk.check_all()
    end

    test "check_all/0 degrades gracefully for a configured but nonexistent root" do
      path = "/nonexistent/cinder-disk-test-#{System.unique_integer([:positive])}"
      Application.put_env(:cinder, :movies_library_path, path)
      Application.delete_env(:cinder, :tv_library_path)

      assert [%{kind: :movies, path: ^path, status: {:error, :enoent}}] = Disk.check_all()
    end
  end
end
