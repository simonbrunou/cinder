defmodule Cinder.Repo.Migrations.AddMovieEpisodeCheckConstraints do
  use Ecto.Migration

  # SQLite has no `ALTER TABLE ADD CONSTRAINT` (and `{:modify, ...}` on an existing column isn't
  # supported by ecto_sqlite3 either — see connection.ex's `column_change/2`), so a CHECK on an
  # already-existing column requires the full rebuild recipe from the SQLite docs ("Making Other
  # Kinds Of Table Schema Changes"): create the new table, copy the data across, drop the old
  # table, rename the new one into place, then rebuild its indexes.
  #
  # CRITICAL: the rebuild MUST run with `PRAGMA foreign_keys = OFF`. With enforcement on,
  # `DROP TABLE` performs an implicit `DELETE FROM` that FIRES `ON DELETE CASCADE` on every
  # child table — here `title_aliases.movie_id`, `blocked_releases.movie_id`, and
  # `episode_coordinate_memberships.episode_id` would be silently wiped on any populated DB
  # (sqlite.org/lang_droptable.html; the docs' 12-step recipe requires the pragma for exactly
  # this reason). The pragma is a no-op while a transaction is open, hence
  # `@disable_ddl_transaction` + our own explicit BEGIN/COMMIT around the rebuild, with
  # `PRAGMA foreign_key_check` inside the transaction as the integrity proof.
  #
  # This needs synchronous read-then-write (read the AUTOINCREMENT high-water mark, then use it in
  # a later statement in the same pass — see `rebuild_table/4`), which Ecto.Migration's queued
  # `execute/1` can't give an `up/0`/`down/0`-style migration (queued commands run only after the
  # callback returns), so — like `drop_episode_import_attempts.exs` — this runs raw DDL straight
  # through the checked-out connection instead.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @movies_columns ~w(
    id tmdb_id title year poster_path status inserted_at updated_at imdb_id download_id
    file_path import_attempts search_attempts download_protocol original_language
    preferred_language imported_resolution imported_size imported_language imported_source
    release_title overview runtime genres vote_average release_date imported_audio_languages
    imported_embedded_subtitles imported_sidecar_subtitles download_progress download_speed
    download_eta media_profile release_policy_snapshot verification_hold_origin
    anime_hold_reason content_path localizations
  )

  @episodes_columns ~w(
    id season_id tmdb_episode_id episode_number title air_date monitored inserted_at
    updated_at file_path grab_id search_attempts imported_resolution imported_size
    imported_language imported_source imported_audio_languages imported_embedded_subtitles
    imported_sidecar_subtitles classification classification_source classification_label
    localizations
  )

  @episodes_index_sqls [
    ~s|CREATE INDEX "episodes_season_id_index" ON "episodes" ("season_id")|,
    ~s|CREATE UNIQUE INDEX "episodes_season_id_episode_number_index" ON "episodes" ("season_id", "episode_number")|,
    ~s|CREATE INDEX "episodes_grab_id_index" ON "episodes" ("grab_id")|,
    ~s|CREATE INDEX "episodes_wanted_index" ON "episodes" ("air_date") WHERE file_path IS NULL AND grab_id IS NULL AND monitored = 1|
  ]

  @movies_index_sqls [~s|CREATE UNIQUE INDEX "movies_tmdb_id_index" ON "movies" ("tmdb_id")|]

  def up, do: rebuild_all(checked?: true)

  def down, do: rebuild_all(checked?: false)

  # Everything MUST run on one pinned connection (`checkout/1`): with the DDL transaction
  # disabled, each bare query would otherwise check out an arbitrary pool connection — the
  # pragma lands on one connection, BEGIN on another (leaving `foreign_keys` ON where the
  # DROP runs, resurrecting the cascade), and ROLLBACK on a third with no transaction at
  # all (the exact failure the container CI caught with POOL_SIZE > 1).
  defp rebuild_all(checked?: checked?) do
    repo().checkout(fn ->
      query!("PRAGMA foreign_keys = OFF")

      # The `after` covers every failure on this connection, including BEGIN IMMEDIATE
      # itself — not just a failure inside the transaction — so a rejected rebuild never
      # returns this checked-out connection to the pool with enforcement left disabled.
      try do
        query!("BEGIN IMMEDIATE")

        try do
          rebuild_table(
            "movies",
            @movies_columns,
            movies_create_sql(checked?: checked?),
            @movies_index_sqls
          )

          rebuild_table(
            "episodes",
            @episodes_columns,
            episodes_create_sql(checked?: checked?),
            @episodes_index_sqls
          )

          verify_foreign_keys!()
          query!("COMMIT")
        rescue
          exception ->
            # Best-effort: never let a failed ROLLBACK mask the original error.
            try do
              query!("ROLLBACK")
            rescue
              _rollback_failure -> :ok
            end

            reraise exception, __STACKTRACE__
        end
      after
        query!("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp movies_create_sql(checked?: checked?) do
    """
    CREATE TABLE "movies_new" (
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
      "localizations" TEXT DEFAULT ('{}')#{movies_checks(checked?)}
    )
    """
  end

  defp movies_checks(false), do: ""

  defp movies_checks(true) do
    """
    ,
        CONSTRAINT movies_import_attempts_non_negative CHECK (import_attempts >= 0),
        CONSTRAINT movies_search_attempts_non_negative CHECK (search_attempts >= 0)
    """
  end

  defp episodes_create_sql(checked?: checked?) do
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
      "localizations" TEXT DEFAULT ('{}')#{episodes_checks(checked?)}
    )
    """
  end

  defp episodes_checks(false), do: ""

  defp episodes_checks(true) do
    """
    ,
        CONSTRAINT episodes_search_attempts_non_negative CHECK (search_attempts >= 0),
        CONSTRAINT episodes_file_path_grab_id_mutually_exclusive
          CHECK (NOT (file_path IS NOT NULL AND grab_id IS NOT NULL))
    """
  end

  # Shared rebuild recipe: create `<table>_new` (caller-supplied DDL), copy every row across by
  # explicit column list (never `SELECT *` — the two schemas must line up exactly regardless of
  # how a future migration reorders `.schema` output), preserve the AUTOINCREMENT high-water mark
  # (a plain copy only carries forward the *surviving* rows' max id, which would let a fresh
  # insert reissue an id a deleted row already used), drop the old table, rename the new one into
  # place, then recreate its indexes.
  defp rebuild_table(table, columns, create_new_sql, index_sqls) do
    old_seq = current_autoincrement_seq(table)
    column_list = Enum.map_join(columns, ", ", &~s("#{&1}"))

    query!(create_new_sql)
    query!(~s|INSERT INTO "#{table}_new" (#{column_list}) SELECT #{column_list} FROM "#{table}"|)
    query!(~s|DROP TABLE "#{table}"|)
    query!(~s|ALTER TABLE "#{table}_new" RENAME TO "#{table}"|)
    Enum.each(index_sqls, &query!/1)
    restore_autoincrement_seq(table, old_seq)
  end

  defp current_autoincrement_seq(table) do
    case query!("SELECT seq FROM sqlite_sequence WHERE name = '#{table}'").rows do
      [[seq]] -> seq
      [] -> 0
    end
  end

  # No-op (0 rows updated) when the table never had a sqlite_sequence entry to begin with, or
  # when the surviving rows already carry a higher id than the old high-water mark.
  defp restore_autoincrement_seq(table, old_seq) do
    query!("UPDATE sqlite_sequence SET seq = MAX(seq, #{old_seq}) WHERE name = '#{table}'")
  end

  defp verify_foreign_keys! do
    case query!("PRAGMA foreign_key_check").rows do
      [] -> :ok
      violations -> raise "foreign key violations after table rebuild: #{inspect(violations)}"
    end
  end

  defp query!(sql), do: Ecto.Adapters.SQL.query!(repo(), sql)
end
