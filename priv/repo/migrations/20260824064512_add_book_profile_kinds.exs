defmodule Cinder.Repo.Migrations.AddBookProfileKinds do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @columns ~w(id name kind handling library_path inserted_at updated_at)

  @index_sqls [
    ~s|CREATE UNIQUE INDEX "media_profiles_kind_name_unique" ON "media_profiles" ("kind", "name")|
  ]

  @trigger_names ~w(
    media_profiles_references_integrity_update
    movies_profile_integrity_insert
    movies_profile_integrity_update
    requests_profile_integrity_insert
    requests_profile_integrity_update
    series_profile_integrity_insert
    series_profile_integrity_update
  )

  def up, do: rebuild(book_kinds?: true)
  def down, do: rebuild(book_kinds?: false)

  defp rebuild(book_kinds?: book_kinds?) do
    repo().checkout(fn ->
      query!("PRAGMA foreign_keys = OFF")

      # `after`, not a trailing statement: a failed BEGIN, a rescued rebuild, or down/0 refusing
      # an existing book profile all leave this checked-out connection in the pool, and it must
      # never go back with foreign-key enforcement disabled.
      try do
        query!("BEGIN IMMEDIATE")
        rebuild_in_transaction(book_kinds?)
      after
        query!("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp rebuild_in_transaction(book_kinds?) do
    try do
      unless book_kinds?, do: ensure_no_book_profiles!()

      old_seq = current_autoincrement_seq()
      trigger_sqls = capture_profile_integrity_triggers!()
      columns = Enum.map_join(@columns, ", ", &~s("#{&1}"))

      query!(create_sql(book_kinds?: book_kinds?))

      query!(
        ~s|INSERT INTO "media_profiles_new" (#{columns}) SELECT #{columns} FROM "media_profiles"|
      )

      drop_profile_integrity_triggers!(trigger_sqls)
      query!(~s|DROP TABLE "media_profiles"|)
      query!(~s|ALTER TABLE "media_profiles_new" RENAME TO "media_profiles"|)
      Enum.each(@index_sqls, &query!/1)
      recreate_profile_integrity_triggers!(trigger_sqls)
      restore_autoincrement_seq(old_seq)
      verify_foreign_keys!()
      query!("COMMIT")
      verify_profile_integrity_triggers!()
    rescue
      exception ->
        try do
          query!("ROLLBACK")
        rescue
          _rollback_failure -> :ok
        end

        reraise exception, __STACKTRACE__
    end
  end

  defp create_sql(book_kinds?: book_kinds?) do
    """
    CREATE TABLE "media_profiles_new" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "name" TEXT COLLATE NOCASE NOT NULL
        CONSTRAINT media_profiles_name_trimmed
        CHECK (name = trim(name) AND length(name) > 0),
      "kind" TEXT NOT NULL
        CONSTRAINT media_profiles_kind_valid
        CHECK (kind IN (#{kinds(book_kinds?)})),
      "handling" TEXT NOT NULL
        CONSTRAINT media_profiles_handling_valid
        CHECK (handling IN ('standard', 'anime')),
      "library_path" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
      #{handling_for_kind_check(book_kinds?)}
    )
    """
  end

  defp kinds(true), do: "'movies', 'tv', 'books', 'audiobooks'"
  defp kinds(false), do: "'movies', 'tv'"

  defp handling_for_kind_check(false), do: ""

  defp handling_for_kind_check(true) do
    """
    , CONSTRAINT media_profiles_handling_valid_for_kind
        CHECK (kind IN ('movies', 'tv') OR handling = 'standard')
    """
  end

  # sqlite_master preserves each exact CREATE TRIGGER statement, including its WHEN clause.
  defp capture_profile_integrity_triggers! do
    rows =
      query!("""
      SELECT name, sql FROM sqlite_master
      WHERE type = 'trigger' AND sql LIKE '%media_profiles%'
      ORDER BY name
      """).rows

    assert_expected_trigger_names!(Enum.map(rows, &hd/1))
    Enum.map(rows, fn [name, sql] -> {name, sql} end)
  end

  defp drop_profile_integrity_triggers!(trigger_sqls) do
    Enum.each(trigger_sqls, fn {name, _sql} -> query!(~s|DROP TRIGGER "#{name}"|) end)
  end

  defp recreate_profile_integrity_triggers!(trigger_sqls) do
    Enum.each(trigger_sqls, fn {_name, sql} -> query!(sql) end)
  end

  defp verify_profile_integrity_triggers! do
    names =
      query!("""
      SELECT name FROM sqlite_master
      WHERE type = 'trigger' AND sql LIKE '%media_profiles%'
      ORDER BY name
      """).rows
      |> List.flatten()

    assert_expected_trigger_names!(names)
  end

  defp assert_expected_trigger_names!(names) do
    names = Enum.sort(names)
    expected = Enum.sort(@trigger_names)

    if names != expected do
      raise "unexpected media_profiles triggers: expected #{inspect(expected)}, got #{inspect(names)}"
    end
  end

  defp ensure_no_book_profiles! do
    case query!("""
         SELECT kind, name FROM media_profiles
         WHERE kind IN ('books', 'audiobooks')
         LIMIT 1
         """).rows do
      [] ->
        :ok

      [[kind, name]] ->
        raise "cannot roll back book profile kinds while #{kind} profile #{inspect(name)} exists"
    end
  end

  defp current_autoincrement_seq do
    case query!("SELECT seq FROM sqlite_sequence WHERE name = 'media_profiles'").rows do
      [[seq]] -> seq
      [] -> 0
    end
  end

  defp restore_autoincrement_seq(old_seq) do
    query!("UPDATE sqlite_sequence SET seq = MAX(seq, #{old_seq}) WHERE name = 'media_profiles'")
  end

  defp verify_foreign_keys! do
    case query!("PRAGMA foreign_key_check").rows do
      [] ->
        :ok

      violations ->
        raise "foreign key violations after media_profiles rebuild: #{inspect(violations)}"
    end
  end

  defp query!(sql), do: Ecto.Adapters.SQL.query!(repo(), sql)
end
