defmodule Cinder.Repo.Migrations.WidenBookFilesForAudiobooks do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Columns shared by both the pre- and post-widening table shape. The five new columns
  # (narrator/duration_seconds/track_number/disc_number/chapter_count) exist only on the widened
  # side, so they are never in this list — `up/0` leaves them NULL for copied e-book rows, and
  # `down/0` simply does not carry them back.
  @shared_columns ~w(id book_target_id edition_id path size format inserted_at updated_at)

  def up, do: rebuild(audiobook_formats?: true)
  def down, do: rebuild(audiobook_formats?: false)

  defp rebuild(audiobook_formats?: audiobook_formats?) do
    repo().checkout(fn ->
      query!("PRAGMA foreign_keys = OFF")

      # `after`, not a trailing statement: a failed BEGIN, a rescued rebuild, or down/0 refusing
      # an existing audiobook file all leave this checked-out connection in the pool, and it must
      # never go back with foreign-key enforcement disabled.
      try do
        query!("BEGIN IMMEDIATE")
        rebuild_in_transaction(audiobook_formats?)
      after
        query!("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp rebuild_in_transaction(audiobook_formats?) do
    try do
      unless audiobook_formats?, do: ensure_no_audiobook_files!()

      old_seq = current_autoincrement_seq()
      trigger_sqls = capture_book_files_triggers!()
      columns = Enum.map_join(@shared_columns, ", ", &~s("#{&1}"))

      query!(create_sql(audiobook_formats?: audiobook_formats?))

      query!(~s|INSERT INTO "book_files_new" (#{columns}) SELECT #{columns} FROM "book_files"|)

      drop_book_files_triggers!(trigger_sqls)
      query!(~s|DROP TABLE "book_files"|)
      query!(~s|ALTER TABLE "book_files_new" RENAME TO "book_files"|)
      recreate_book_files_indexes!()
      recreate_book_files_triggers!(trigger_sqls)
      restore_autoincrement_seq(old_seq)
      verify_foreign_keys!()
      query!("COMMIT")
      verify_book_files_triggers!()
    rescue
      exception ->
        stacktrace = __STACKTRACE__
        rollback_after_failure(exception, stacktrace)
    end
  end

  # A plain `query!("ROLLBACK")` here that swallowed its own failure (`rescue _ -> :ok`) made a
  # double fault indistinguishable from a single one: `rebuild/1`'s `after` still runs `PRAGMA
  # foreign_keys = ON`, which SQLite makes a no-op while a transaction is still pending, so a
  # connection whose ROLLBACK also failed went back to the pool mid-transaction with FK
  # enforcement silently off, reporting only the ORIGINAL (now-misleading) error. Neither
  # `DBConnection.run/3`'s exception path (a plain `checkin`, never a disconnect — the pool has no
  # public API from here to force one) nor `Exqlite.Connection`'s own leaked-transaction check
  # (`handle_status/2` reads `transaction_status`, which only `handle_begin`/`handle_commit`/
  # `handle_rollback` update — never the raw `BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK` this migration
  # issues) can rescue this from outside, so the only thing within reach is to make a double fault
  # LOUD and unmistakable rather than silently indistinguishable from a clean single failure.
  defp rollback_after_failure(exception, stacktrace) do
    try do
      query!("ROLLBACK")
    rescue
      rollback_exception ->
        raise RuntimeError,
              "book_files rebuild failed, and the ROLLBACK meant to clean up after it ALSO " <>
                "failed — this connection may still be inside an open transaction with " <>
                "foreign keys disabled and must not be reused; restart the process before " <>
                "retrying. " <>
                "Original error: #{Exception.format(:error, exception, stacktrace)}\n" <>
                "Rollback error: #{Exception.format(:error, rollback_exception, __STACKTRACE__)}"
    end

    reraise exception, stacktrace
  end

  defp create_sql(audiobook_formats?: audiobook_formats?) do
    """
    CREATE TABLE "book_files_new" (
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
        CONSTRAINT "book_files_format_valid"
        CHECK (format IN (#{formats(audiobook_formats?)}))
      #{audiobook_columns(audiobook_formats?)},
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """
  end

  # M4B and MP3 only (B7's own judgment, §0.1 of the audiobook plan — not contract-derived; the
  # contract only names M4B as preferred and gestures at "common multipart audio containers").
  defp formats(true), do: "'epub', 'azw3', 'mobi', 'm4b', 'mp3'"
  defp formats(false), do: "'epub', 'azw3', 'mobi'"

  defp audiobook_columns(false), do: ""

  defp audiobook_columns(true) do
    """
    ,
      "narrator" TEXT,
      "duration_seconds" INTEGER,
      "track_number" INTEGER,
      "disc_number" INTEGER,
      "chapter_count" INTEGER
    """
  end

  defp recreate_book_files_indexes! do
    query!(~s|CREATE UNIQUE INDEX "book_files_path_index" ON "book_files" ("path")|)
    query!(~s|CREATE INDEX "book_files_book_target_id_index" ON "book_files" ("book_target_id")|)
    query!(~s|CREATE INDEX "book_files_edition_id_index" ON "book_files" ("edition_id")|)
  end

  # sqlite_master preserves each exact CREATE TRIGGER statement, including its WHEN clause. No
  # trigger references book_files today (verified against the live schema: `SELECT name FROM
  # sqlite_master WHERE type = 'trigger' AND sql LIKE '%book_files%'` returns zero rows) — this is
  # the same generic capture-and-reapply recipe `20260824064512_add_book_profile_kinds.exs` uses,
  # kept here so a future trigger on book_files (should one ever exist) is not silently dropped by
  # this migration or any later one copying it.
  defp capture_book_files_triggers! do
    rows =
      query!("""
      SELECT name, sql FROM sqlite_master
      WHERE type = 'trigger' AND sql LIKE '%book_files%'
      ORDER BY name
      """).rows

    assert_no_book_files_triggers!(Enum.map(rows, &hd/1))
    Enum.map(rows, fn [name, sql] -> {name, sql} end)
  end

  defp drop_book_files_triggers!(trigger_sqls) do
    Enum.each(trigger_sqls, fn {name, _sql} -> query!(~s|DROP TRIGGER "#{name}"|) end)
  end

  defp recreate_book_files_triggers!(trigger_sqls) do
    Enum.each(trigger_sqls, fn {_name, sql} -> query!(sql) end)
  end

  defp verify_book_files_triggers! do
    names =
      query!("""
      SELECT name FROM sqlite_master
      WHERE type = 'trigger' AND sql LIKE '%book_files%'
      ORDER BY name
      """).rows
      |> List.flatten()

    assert_no_book_files_triggers!(names)
  end

  defp assert_no_book_files_triggers!(names) do
    if names != [] do
      raise "unexpected book_files triggers: #{inspect(names)} (this migration does not carry them)"
    end
  end

  defp ensure_no_audiobook_files! do
    case query!("""
         SELECT id, format FROM book_files
         WHERE format IN ('m4b', 'mp3')
         LIMIT 1
         """).rows do
      [] ->
        :ok

      [[id, format]] ->
        raise "cannot roll back audiobook book_files formats while file #{id} (#{format}) exists"
    end
  end

  defp current_autoincrement_seq do
    case query!("SELECT seq FROM sqlite_sequence WHERE name = 'book_files'").rows do
      [[seq]] -> seq
      [] -> 0
    end
  end

  defp restore_autoincrement_seq(old_seq) do
    query!("UPDATE sqlite_sequence SET seq = MAX(seq, #{old_seq}) WHERE name = 'book_files'")
  end

  defp verify_foreign_keys! do
    case query!("PRAGMA foreign_key_check").rows do
      [] ->
        :ok

      violations ->
        raise "foreign key violations after book_files rebuild: #{inspect(violations)}"
    end
  end

  defp query!(sql), do: Ecto.Adapters.SQL.query!(repo(), sql)
end
