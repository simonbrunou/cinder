defmodule Cinder.DatabaseBackupTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.DatabaseBackup

  @tag :unboxed
  @tag :tmp_dir
  test "scheduled snapshots are verified, private, and retention-bounded", %{tmp_dir: tmp} do
    saved = Application.get_env(:cinder, DatabaseBackup)
    Application.put_env(:cinder, DatabaseBackup, backup_dir: tmp, retention: 2)
    on_exit(fn -> restore_config(saved) end)

    assert {:ok, first} = DatabaseBackup.create_scheduled()
    assert :ok = DatabaseBackup.verify(first)
    assert File.stat!(first).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(tmp).mode |> Bitwise.band(0o777) == 0o700

    assert {:ok, second} = DatabaseBackup.create_scheduled()
    assert {:ok, third} = DatabaseBackup.create_scheduled()

    assert Enum.sort(Path.wildcard(Path.join(tmp, "cinder-backup-*.sqlite3"))) ==
             Enum.sort([second, third])

    assert Path.wildcard(Path.join(tmp, ".cinder-backup-pending-*.sqlite3")) == []
    refute File.exists?(first)
  end

  @tag :tmp_dir
  test "verification rejects a corrupt restore candidate", %{tmp_dir: tmp} do
    path = Path.join(tmp, "corrupt.sqlite3")
    File.write!(path, "not sqlite")

    assert {:error, _reason} = DatabaseBackup.verify(path)
  end

  @tag :tmp_dir
  test "refuses an existing destination without changing it", %{tmp_dir: tmp} do
    path = Path.join(tmp, "existing.sqlite3")
    File.write!(path, "operator-owned")

    log = capture_log(fn -> assert {:error, :eexist} = DatabaseBackup.create(path) end)

    assert log =~ "database snapshot failed: :eexist"
    assert File.read!(path) == "operator-owned"
  end

  defp restore_config(nil), do: Application.delete_env(:cinder, DatabaseBackup)
  defp restore_config(config), do: Application.put_env(:cinder, DatabaseBackup, config)
end
