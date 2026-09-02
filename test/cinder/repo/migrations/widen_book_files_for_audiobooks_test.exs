unless Code.ensure_loaded?(Cinder.Repo.Migrations.WidenBookFilesForAudiobooks) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260902090000_widen_book_files_for_audiobooks.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.WidenBookFilesForAudiobooksTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.WidenBookFilesForAudiobooks
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-book-files-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database, pool_size: 1, telemetry_prefix: [:cinder, :book_files_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    # The two tables `book_files` foreign-keys against. Minimal shape — this migration never
    # touches them, so only enough columns to satisfy the FKs and a query join.
    query!("CREATE TABLE book_targets (id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL)")
    query!("CREATE TABLE book_editions (id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL)")

    # The exact pre-migration `book_files` DDL, verified against the live schema
    # (`20260831090000_create_book_grabs_and_files.exs`).
    query!("""
    CREATE TABLE "book_files" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "book_target_id" INTEGER NOT NULL
        CONSTRAINT "book_files_book_target_id_fkey"
        REFERENCES "book_targets"("id") ON DELETE CASCADE,
      "edition_id" INTEGER
        CONSTRAINT "book_files_edition_id_fkey"
        REFERENCES "book_editions"("id") ON DELETE SET NULL,
      "path" TEXT NOT NULL,
      "size" INTEGER,
      "format" TEXT NOT NULL
        CONSTRAINT book_files_format_valid
        CHECK (format IN ('epub', 'azw3', 'mobi')),
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    query!(~s|CREATE UNIQUE INDEX "book_files_path_index" ON "book_files" ("path")|)
    query!(~s|CREATE INDEX "book_files_book_target_id_index" ON "book_files" ("book_target_id")|)
    query!(~s|CREATE INDEX "book_files_edition_id_index" ON "book_files" ("edition_id")|)

    query!("INSERT INTO book_targets (id, work_id) VALUES (1, 100)")
    query!("INSERT INTO book_editions (id, work_id) VALUES (1, 100)")

    :ok
  end

  test "up/0 widens the CHECK, preserves existing e-book rows, indexes, and foreign keys" do
    query!("""
    INSERT INTO book_files
      (id, book_target_id, edition_id, path, size, format, inserted_at, updated_at)
    VALUES
      (1, 1, 1, '/library/beloved.epub', 4096, 'epub', '2026-01-01T00:00:00', '2026-01-01T00:00:00'),
      (2, 1, NULL, '/library/dune.azw3', 8192, 'azw3', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert_raise Exqlite.Error, ~r/book_files_format_valid/, fn ->
      query!("""
      INSERT INTO book_files (id, book_target_id, path, format, inserted_at, updated_at)
      VALUES (3, 1, '/library/pre.m4b', 'm4b', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
      """)
    end

    :ok = Ecto.Migrator.up(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)

    # Every pre-existing row survived with its id, path, size, and format unchanged.
    assert %{
             rows: [
               [1, "/library/beloved.epub", 4096, "epub"],
               [2, "/library/dune.azw3", 8192, "azw3"]
             ]
           } =
             query!("SELECT id, path, size, format FROM book_files ORDER BY id")

    # The new file-level columns exist and are NULL for the copied e-book rows.
    assert %{rows: [[nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil]]} =
             query!("""
             SELECT narrator, duration_seconds, track_number, disc_number, chapter_count
             FROM book_files ORDER BY id
             """)

    # The unique path index, the two plain indexes, and both foreign keys all still exist.
    assert %{rows: [["book_files_book_target_id_index"], ["book_files_edition_id_index"]]} =
             query!("""
             SELECT name FROM sqlite_master
             WHERE type = 'index' AND tbl_name = 'book_files' AND name != 'book_files_path_index'
             ORDER BY name
             """)

    assert_raise Exqlite.Error, ~r/UNIQUE constraint failed: book_files.path/, fn ->
      query!("""
      INSERT INTO book_files (book_target_id, path, format, inserted_at, updated_at)
      VALUES (1, '/library/beloved.epub', 'mobi', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
      """)
    end

    assert %{rows: []} = query!("PRAGMA foreign_key_check")

    assert_raise Exqlite.Error, fn ->
      query!("""
      INSERT INTO book_files (book_target_id, path, format, inserted_at, updated_at)
      VALUES (999, '/library/orphan.epub', 'epub', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
      """)
    end

    # An m4b/mp3 insert — rejected before the migration — is now accepted, and carries the new
    # audiobook file-level facts.
    assert %{num_rows: 1} =
             query!("""
             INSERT INTO book_files
               (book_target_id, path, size, format, narrator, duration_seconds, track_number,
                disc_number, chapter_count, inserted_at, updated_at)
             VALUES
               (1, '/library/dune.m4b', 500000000, 'm4b', 'Scott Brick', 38000, 1, 1, 42,
                '2026-01-01T00:00:00', '2026-01-01T00:00:00')
             """)

    assert_raise Exqlite.Error, ~r/book_files_format_valid/, fn ->
      query!("""
      INSERT INTO book_files (book_target_id, path, format, inserted_at, updated_at)
      VALUES (1, '/library/bad.pdf', 'pdf', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
      """)
    end

    # A fresh row's id continues from the preserved autoincrement sequence rather than reusing 1.
    assert %{rows: [[id]]} =
             query!("SELECT id FROM book_files WHERE path = '/library/dune.m4b'")

    assert id > 2
  end

  test "down/0 refuses to roll back while an m4b/mp3 row still exists" do
    :ok = Ecto.Migrator.up(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)

    query!("""
    INSERT INTO book_files (book_target_id, path, size, format, inserted_at, updated_at)
    VALUES (1, '/library/dune.m4b', 500000000, 'm4b', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert_raise RuntimeError, ~r/cannot roll back/, fn ->
      Ecto.Migrator.down(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)
    end

    # The failed rollback left foreign keys re-enabled rather than stuck off.
    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")
  end

  test "down/0 rebuilds the narrower table when no audiobook rows exist" do
    :ok = Ecto.Migrator.up(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)

    query!("""
    INSERT INTO book_files (book_target_id, path, size, format, inserted_at, updated_at)
    VALUES (1, '/library/beloved.epub', 4096, 'epub', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    :ok = Ecto.Migrator.down(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)

    assert %{rows: [[1, "/library/beloved.epub", "epub"]]} =
             query!("SELECT id, path, format FROM book_files ORDER BY id")

    assert_raise Exqlite.Error, ~r/book_files_format_valid/, fn ->
      query!("""
      INSERT INTO book_files (book_target_id, path, format, inserted_at, updated_at)
      VALUES (1, '/library/dune.m4b', 'm4b', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
      """)
    end

    assert %{rows: []} =
             query!("""
             SELECT name FROM pragma_table_info('book_files') WHERE name = 'narrator'
             """)
  end

  test "no trigger references book_files before or after the rebuild" do
    query!(~s|CREATE TABLE media_profiles (id INTEGER PRIMARY KEY, kind TEXT)|)

    query!("""
    CREATE TRIGGER book_targets_profile_integrity_insert
    BEFORE INSERT ON book_targets
    WHEN NEW.work_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM media_profiles)
    BEGIN
      SELECT RAISE(ABORT, 'unused');
    END
    """)

    before_triggers =
      query!("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").rows

    :ok = Ecto.Migrator.up(Repo, 20_260_902_090_000, WidenBookFilesForAudiobooks, log: false)

    after_triggers =
      query!("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").rows

    # book_targets's own trigger is untouched by a migration that only rebuilds book_files.
    assert before_triggers == after_triggers
    assert before_triggers == [["book_targets_profile_integrity_insert"]]
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
