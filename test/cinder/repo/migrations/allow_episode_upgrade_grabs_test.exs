unless Code.ensure_loaded?(Cinder.Repo.Migrations.AllowEpisodeUpgradeGrabs) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260726234308_allow_episode_upgrade_grabs.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.AllowEpisodeUpgradeGrabsTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.AllowEpisodeUpgradeGrabs
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-episode-upgrade-grabs-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database,
       pool_size: 1,
       telemetry_prefix: [:cinder, :episode_upgrade_grabs_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    query!("CREATE TABLE seasons (id INTEGER PRIMARY KEY)")
    query!("CREATE TABLE grabs (id INTEGER PRIMARY KEY)")
    query!("INSERT INTO seasons (id) VALUES (1)")
    query!("INSERT INTO grabs (id) VALUES (1)")

    # The pre-migration shape: both CHECKs from `20260726180000_add_movie_episode_check_constraints`
    # plus the `part_file_paths` column added by `20260726211432`.
    query!("""
    CREATE TABLE "episodes" (
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
      CONSTRAINT episodes_search_attempts_non_negative CHECK (search_attempts >= 0),
      CONSTRAINT episodes_file_path_grab_id_mutually_exclusive
        CHECK (NOT (file_path IS NOT NULL AND grab_id IS NOT NULL))
    )
    """)

    query!(~s|CREATE INDEX "episodes_season_id_index" ON "episodes" ("season_id")|)

    query!(
      ~s|CREATE UNIQUE INDEX "episodes_season_id_episode_number_index" ON "episodes" ("season_id", "episode_number")|
    )

    query!(~s|CREATE INDEX "episodes_grab_id_index" ON "episodes" ("grab_id")|)

    :ok
  end

  test "up/0 drops the mutually-exclusive CHECK, preserves rows, and restores foreign_keys" do
    query!("""
    INSERT INTO episodes (season_id, episode_number, inserted_at, updated_at)
    VALUES (1, 1, '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    :ok = Ecto.Migrator.up(Repo, 20_260_726_234_308, AllowEpisodeUpgradeGrabs, log: false)

    assert %{rows: [[1]]} = query!("SELECT id FROM episodes")
    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")

    # An available episode with an active upgrade grab is now legal.
    query!("""
    UPDATE episodes SET file_path = '/lib/ep.mkv', grab_id = 1 WHERE id = 1
    """)

    assert %{rows: [["/lib/ep.mkv", 1]]} = query!("SELECT file_path, grab_id FROM episodes")
  end

  # Reproduces issue #508: rolling back onto the old mutually-exclusive CHECK correctly refuses
  # to downgrade a row that is only valid post-upgrade. The rescue branch used to re-raise
  # before its own `PRAGMA foreign_keys = ON`, leaving the checked-out connection's enforcement
  # disabled even though the rollback failed.
  test "a rejected rollback restores foreign_keys enforcement on the same connection" do
    :ok = Ecto.Migrator.up(Repo, 20_260_726_234_308, AllowEpisodeUpgradeGrabs, log: false)

    query!("""
    INSERT INTO episodes (season_id, episode_number, file_path, grab_id, inserted_at, updated_at)
    VALUES (1, 1, '/lib/ep.mkv', 1, '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert_raise Exqlite.Error, ~r/episodes_file_path_grab_id_mutually_exclusive/, fn ->
      Ecto.Migrator.down(Repo, 20_260_726_234_308, AllowEpisodeUpgradeGrabs, log: false)
    end

    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")

    # The old table is untouched — the failed rebuild never dropped it.
    assert %{rows: [["/lib/ep.mkv", 1]]} = query!("SELECT file_path, grab_id FROM episodes")
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
