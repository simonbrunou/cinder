defmodule Cinder.DatabaseBackupTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Books
  alias Cinder.Books.BookFile
  alias Cinder.Catalog
  alias Cinder.DatabaseBackup
  alias Cinder.Repo
  alias Exqlite.Sqlite3

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

  # `@tag :unboxed` because `VACUUM INTO` cannot run inside the Sandbox transaction every other
  # test in this file (implicitly) uses — see the `:unboxed` invariant comment in
  # `book_poller_test.exs` (real, committed rows; safe here because this module is `async:
  # false`, so no `async: true` test can ever observe them mid-flight; `try/after` cleanup runs
  # in this test's own process, not `on_exit/1`, which would silently no-op against a connection
  # its owner process has already exited).
  @tag :unboxed
  @tag :tmp_dir
  test "a book target and its published file round-trip through backup and restore", %{
    tmp_dir: tmp
  } do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: "Backup Round Trip",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: "Backup Author",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Backup Ebooks #{id}",
        kind: :ebook,
        handling: :standard,
        library_path: tmp
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)

    file_path = Path.join(tmp, "book.epub")

    {:ok, file} =
      %BookFile{}
      |> BookFile.changeset(%{
        book_target_id: target.id,
        path: file_path,
        format: :epub,
        size: 123
      })
      |> Repo.insert()

    try do
      backup_path = Path.join(tmp, "round-trip.sqlite3")
      assert :ok = DatabaseBackup.create(backup_path)

      {:ok, database} = Sqlite3.open(backup_path)

      try do
        assert query(database, "PRAGMA integrity_check") == [["ok"]]

        assert query(database, "SELECT status FROM book_targets WHERE id = ?", [target.id]) == [
                 ["monitored"]
               ]

        assert query(
                 database,
                 "SELECT path, format FROM book_files WHERE book_target_id = ?",
                 [target.id]
               ) == [[file.path, "epub"]]
      after
        Sqlite3.close(database)
      end
    after
      Repo.delete_all(from f in BookFile, where: f.id == ^file.id)
      Repo.delete_all(from t in Cinder.Books.BookTarget, where: t.id == ^target.id)
      Repo.delete_all(from c in Cinder.Books.Credit, where: c.work_id == ^work.id)
      Repo.delete_all(from w in Books.Work, where: w.id == ^work.id)
      Repo.delete_all(from a in Cinder.Books.Author, where: a.id == ^author.id)
      Repo.delete_all(from p in Catalog.Profile, where: p.id == ^profile.id)
    end
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

  defp query(database, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(database, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(database, statement)
      rows
    after
      Sqlite3.release(database, statement)
    end
  end
end
