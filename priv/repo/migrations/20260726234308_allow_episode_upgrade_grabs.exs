defmodule Cinder.Repo.Migrations.AllowEpisodeUpgradeGrabs do
  use Ecto.Migration

  # SQLite cannot drop a CHECK constraint in place. Rebuild only episodes, with foreign-key
  # enforcement disabled on one pinned connection so dropping the old table cannot cascade into
  # episode_coordinate_memberships. This mirrors AddMovieEpisodeCheckConstraints' proven recipe.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @columns ~w(
    id season_id tmdb_episode_id episode_number title air_date monitored inserted_at
    updated_at file_path grab_id search_attempts imported_resolution imported_size
    imported_language imported_source imported_audio_languages imported_embedded_subtitles
    imported_sidecar_subtitles classification classification_source classification_label
    localizations part_file_paths
  )

  @index_sqls [
    ~s|CREATE INDEX "episodes_season_id_index" ON "episodes" ("season_id")|,
    ~s|CREATE UNIQUE INDEX "episodes_season_id_episode_number_index" ON "episodes" ("season_id", "episode_number")|,
    ~s|CREATE INDEX "episodes_grab_id_index" ON "episodes" ("grab_id")|,
    ~s|CREATE INDEX "episodes_wanted_index" ON "episodes" ("air_date") WHERE file_path IS NULL AND grab_id IS NULL AND monitored = 1|
  ]

  def up, do: rebuild(mutually_exclusive?: false)
  def down, do: rebuild(mutually_exclusive?: true)

  defp rebuild(mutually_exclusive?: mutually_exclusive?) do
    repo().checkout(fn ->
      query!("PRAGMA foreign_keys = OFF")
      query!("BEGIN IMMEDIATE")

      try do
        old_seq = current_autoincrement_seq()
        columns = Enum.map_join(@columns, ", ", &~s("#{&1}"))

        query!(create_sql(mutually_exclusive?: mutually_exclusive?))
        query!(~s|INSERT INTO "episodes_new" (#{columns}) SELECT #{columns} FROM "episodes"|)
        query!(~s|DROP TABLE "episodes"|)
        query!(~s|ALTER TABLE "episodes_new" RENAME TO "episodes"|)
        Enum.each(@index_sqls, &query!/1)
        restore_autoincrement_seq(old_seq)
        verify_foreign_keys!()
        query!("COMMIT")
      rescue
        exception ->
          try do
            query!("ROLLBACK")
          rescue
            _rollback_failure -> :ok
          end

          reraise exception, __STACKTRACE__
      end

      query!("PRAGMA foreign_keys = ON")
    end)
  end

  defp create_sql(mutually_exclusive?: mutually_exclusive?) do
    """
    CREATE TABLE "episodes_new" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "season_id" INTEGER NOT NULL
        CONSTRAINT "episodes_season_id_fkey" REFERENCES "seasons"("id") ON DELETE CASCADE,
      "tmdb_episode_id" INTEGER,
      "episode_number" INTEGER NOT NULL,
      "title" TEXT,
      "air_date" TEXT,
      "monitored" INTEGER DEFAULT true NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "file_path" TEXT,
      "grab_id" INTEGER
        CONSTRAINT "episodes_grab_id_fkey" REFERENCES "grabs"("id") ON DELETE SET NULL,
      "search_attempts" INTEGER DEFAULT 0 NOT NULL,
      "imported_resolution" TEXT,
      "imported_size" INTEGER,
      "imported_language" TEXT,
      "imported_source" TEXT,
      "imported_audio_languages" TEXT,
      "imported_embedded_subtitles" TEXT,
      "imported_sidecar_subtitles" TEXT,
      "classification" TEXT DEFAULT 'regular' NOT NULL,
      "classification_source" TEXT DEFAULT 'legacy' NOT NULL,
      "classification_label" TEXT,
      "localizations" TEXT DEFAULT ('{}'),
      "part_file_paths" TEXT DEFAULT ('[]') NOT NULL,
      CONSTRAINT episodes_search_attempts_non_negative CHECK (search_attempts >= 0)
      #{mutually_exclusive_check(mutually_exclusive?)}
    )
    """
  end

  defp mutually_exclusive_check(false), do: ""

  defp mutually_exclusive_check(true) do
    """
    , CONSTRAINT episodes_file_path_grab_id_mutually_exclusive
        CHECK (NOT (file_path IS NOT NULL AND grab_id IS NOT NULL))
    """
  end

  defp current_autoincrement_seq do
    case query!("SELECT seq FROM sqlite_sequence WHERE name = 'episodes'").rows do
      [[seq]] -> seq
      [] -> 0
    end
  end

  defp restore_autoincrement_seq(old_seq) do
    query!("UPDATE sqlite_sequence SET seq = MAX(seq, #{old_seq}) WHERE name = 'episodes'")
  end

  defp verify_foreign_keys! do
    case query!("PRAGMA foreign_key_check").rows do
      [] -> :ok
      violations -> raise "foreign key violations after episodes rebuild: #{inspect(violations)}"
    end
  end

  defp query!(sql), do: Ecto.Adapters.SQL.query!(repo(), sql)
end
