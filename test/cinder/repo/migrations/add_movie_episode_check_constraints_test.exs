unless Code.ensure_loaded?(Cinder.Repo.Migrations.AddMovieEpisodeCheckConstraints) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260726180000_add_movie_episode_check_constraints.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.AddMovieEpisodeCheckConstraintsTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.AddMovieEpisodeCheckConstraints
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-movie-episode-check-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database,
       pool_size: 1,
       telemetry_prefix: [:cinder, :movie_episode_check_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    # The pre-migration shape (no CHECK constraints yet) of every table this migration touches
    # or references, verified against `movies_checks(false)`/`episodes_checks(false)`.
    query!("CREATE TABLE seasons (id INTEGER PRIMARY KEY)")
    query!("CREATE TABLE grabs (id INTEGER PRIMARY KEY)")

    query!("""
    CREATE TABLE "movies" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "tmdb_id" INTEGER NOT NULL,
      "title" TEXT NOT NULL,
      "year" INTEGER,
      "poster_path" TEXT,
      "status" TEXT DEFAULT 'requested' NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "imdb_id" TEXT,
      "download_id" TEXT,
      "file_path" TEXT,
      "import_attempts" INTEGER DEFAULT 0 NOT NULL,
      "search_attempts" INTEGER DEFAULT 0 NOT NULL,
      "download_protocol" TEXT,
      "original_language" TEXT,
      "preferred_language" TEXT DEFAULT 'original' NOT NULL,
      "imported_resolution" TEXT,
      "imported_size" INTEGER,
      "imported_language" TEXT,
      "imported_source" TEXT,
      "release_title" TEXT,
      "overview" TEXT,
      "runtime" INTEGER,
      "genres" TEXT,
      "vote_average" NUMERIC,
      "release_date" TEXT,
      "imported_audio_languages" TEXT,
      "imported_embedded_subtitles" TEXT,
      "imported_sidecar_subtitles" TEXT,
      "download_progress" NUMERIC,
      "download_speed" INTEGER,
      "download_eta" INTEGER,
      "media_profile" TEXT DEFAULT 'auto' NOT NULL,
      "release_policy_snapshot" TEXT,
      "verification_hold_origin" TEXT,
      "anime_hold_reason" TEXT,
      "content_path" TEXT,
      "localizations" TEXT DEFAULT ('{}')
    )
    """)

    query!(~s|CREATE UNIQUE INDEX "movies_tmdb_id_index" ON "movies" ("tmdb_id")|)

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
      "localizations" TEXT DEFAULT ('{}')
    )
    """)

    query!(~s|CREATE INDEX "episodes_season_id_index" ON "episodes" ("season_id")|)

    query!(
      ~s|CREATE UNIQUE INDEX "episodes_season_id_episode_number_index" ON "episodes" ("season_id", "episode_number")|
    )

    query!(~s|CREATE INDEX "episodes_grab_id_index" ON "episodes" ("grab_id")|)

    :ok
  end

  test "up/0 adds the CHECK constraints, preserves rows, and restores foreign_keys" do
    query!("""
    INSERT INTO movies (tmdb_id, title, inserted_at, updated_at)
    VALUES (1, 'Dune', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    :ok = Ecto.Migrator.up(Repo, 20_260_726_180_000, AddMovieEpisodeCheckConstraints, log: false)

    assert %{rows: [[1, "Dune"]]} = query!("SELECT id, title FROM movies")

    assert_raise Exqlite.Error, ~r/movies_search_attempts_non_negative/, fn ->
      query!("UPDATE movies SET search_attempts = -1 WHERE id = 1")
    end

    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")
  end

  # Reproduces issue #508: a legacy row that was legal before this migration (a negative
  # search_attempts) now violates the new CHECK, rolling back the rebuild. The rescue branch
  # used to re-raise before its own `PRAGMA foreign_keys = ON`, leaving the checked-out
  # connection's enforcement disabled even though the migration itself failed.
  test "a rejected rebuild restores foreign_keys enforcement on the same connection" do
    query!("""
    INSERT INTO movies (tmdb_id, title, search_attempts, inserted_at, updated_at)
    VALUES (1, 'Dune', -1, '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert_raise Exqlite.Error, ~r/movies_search_attempts_non_negative/, fn ->
      Ecto.Migrator.up(Repo, 20_260_726_180_000, AddMovieEpisodeCheckConstraints, log: false)
    end

    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")

    # The old table is untouched — the failed rebuild never dropped it.
    assert %{rows: [[1, "Dune", -1]]} =
             query!("SELECT id, title, search_attempts FROM movies")
  end

  test "down/0 removes the CHECK constraints and restores foreign_keys" do
    :ok = Ecto.Migrator.up(Repo, 20_260_726_180_000, AddMovieEpisodeCheckConstraints, log: false)

    :ok =
      Ecto.Migrator.down(Repo, 20_260_726_180_000, AddMovieEpisodeCheckConstraints, log: false)

    query!("""
    INSERT INTO movies (tmdb_id, title, search_attempts, inserted_at, updated_at)
    VALUES (1, 'Dune', -1, '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert %{rows: [[1]]} = query!("PRAGMA foreign_keys")
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
