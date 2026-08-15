defmodule Cinder.Repo.Migrations.CreateNamedMediaProfiles do
  use Ecto.Migration

  def up do
    create table(:media_profiles) do
      add :name, :string,
        null: false,
        collate: :nocase,
        check: %{
          name: "media_profiles_name_trimmed",
          expr: "name = trim(name) AND length(name) > 0"
        }

      add :kind, :string,
        null: false,
        check: %{name: "media_profiles_kind_valid", expr: "kind IN ('movies', 'tv')"}

      add :handling, :string,
        null: false,
        check: %{
          name: "media_profiles_handling_valid",
          expr: "handling IN ('standard', 'anime')"
        }

      add :library_path, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_profiles, [:kind, :name], name: :media_profiles_kind_name_unique)

    alter table(:movies) do
      add :profile_id, references(:media_profiles, on_delete: :restrict)
    end

    alter table(:series) do
      add :profile_id, references(:media_profiles, on_delete: :restrict)
    end

    alter table(:requests) do
      add :proposed_profile_id, references(:media_profiles, on_delete: :restrict)
    end

    create index(:movies, [:profile_id])
    create index(:series, [:profile_id])
    create index(:requests, [:proposed_profile_id])

    execute("""
    INSERT INTO media_profiles (name, kind, handling, inserted_at, updated_at)
    VALUES
      ('Standard', 'movies', 'standard', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
      ('Anime', 'movies', 'anime', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
      ('Standard', 'tv', 'standard', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
      ('Anime', 'tv', 'anime', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """)

    execute("""
    UPDATE movies
    SET profile_id = (
      SELECT id FROM media_profiles
      WHERE kind = 'movies' AND name = CASE movies.media_profile
        WHEN 'standard' THEN 'Standard'
        WHEN 'anime' THEN 'Anime'
      END
    )
    WHERE media_profile IN ('standard', 'anime')
    """)

    execute("""
    UPDATE series
    SET profile_id = (
      SELECT id FROM media_profiles
      WHERE kind = 'tv' AND name = CASE series.media_profile
        WHEN 'standard' THEN 'Standard'
        WHEN 'anime' THEN 'Anime'
      END
    )
    WHERE media_profile IN ('standard', 'anime')
    """)

    execute("""
    UPDATE requests
    SET proposed_profile_id = (
      SELECT id FROM media_profiles
      WHERE kind = CASE requests.target_type
        WHEN 'movie' THEN 'movies'
        ELSE 'tv'
      END AND name = CASE requests.proposed_media_profile
        WHEN 'standard' THEN 'Standard'
        WHEN 'anime' THEN 'Anime'
      END
    )
    WHERE proposed_media_profile IN ('standard', 'anime')
      AND target_type IN ('movie', 'series', 'season', 'episode')
    """)

    create_profile_integrity_triggers()
  end

  def down do
    drop_profile_integrity_triggers()

    drop index(:requests, [:proposed_profile_id])
    drop index(:series, [:profile_id])
    drop index(:movies, [:profile_id])

    alter table(:requests), do: remove(:proposed_profile_id)
    alter table(:series), do: remove(:profile_id)
    alter table(:movies), do: remove(:profile_id)

    drop table(:media_profiles)
  end

  defp create_profile_integrity_triggers do
    for {table, kind, profile_column, handling_column, watched_columns} <- [
          {:movies, "movies", "profile_id", "media_profile", "profile_id, media_profile"},
          {:series, "tv", "profile_id", "media_profile", "profile_id, media_profile"}
        ],
        event <- ["INSERT", "UPDATE OF #{watched_columns}"] do
      suffix = if event == "INSERT", do: "insert", else: "update"

      execute("""
      CREATE TRIGGER #{table}_profile_integrity_#{suffix}
      BEFORE #{event} ON #{table}
      WHEN NEW.#{profile_column} IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM media_profiles
        WHERE id = NEW.#{profile_column}
          AND kind = '#{kind}'
          AND handling = NEW.#{handling_column}
      )
      BEGIN
        SELECT RAISE(ABORT, 'CHECK constraint failed: #{table}_profile_integrity');
      END
      """)
    end

    for event <- ["INSERT", "UPDATE OF proposed_profile_id, proposed_media_profile, target_type"] do
      suffix = if event == "INSERT", do: "insert", else: "update"

      execute("""
      CREATE TRIGGER requests_profile_integrity_#{suffix}
      BEFORE #{event} ON requests
      WHEN NEW.proposed_profile_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM media_profiles
        WHERE id = NEW.proposed_profile_id
          AND handling = NEW.proposed_media_profile
          AND (
            (NEW.target_type = 'movie' AND kind = 'movies') OR
            (NEW.target_type IN ('series', 'season', 'episode') AND kind = 'tv')
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'CHECK constraint failed: requests_profile_integrity');
      END
      """)
    end

    execute("""
    CREATE TRIGGER media_profiles_references_integrity_update
    BEFORE UPDATE OF kind, handling ON media_profiles
    WHEN
      EXISTS (
        SELECT 1 FROM movies
        WHERE profile_id = OLD.id
          AND (NEW.kind != 'movies' OR NEW.handling != media_profile)
      ) OR
      EXISTS (
        SELECT 1 FROM series
        WHERE profile_id = OLD.id
          AND (NEW.kind != 'tv' OR NEW.handling != media_profile)
      ) OR
      EXISTS (
        SELECT 1 FROM requests
        WHERE proposed_profile_id = OLD.id
          AND (
            NEW.handling != proposed_media_profile OR
            NOT (
              (target_type = 'movie' AND NEW.kind = 'movies') OR
              (target_type IN ('series', 'season', 'episode') AND NEW.kind = 'tv')
            )
          )
      )
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: media_profiles_references_integrity');
    END
    """)
  end

  defp drop_profile_integrity_triggers do
    for trigger <- [
          "movies_profile_integrity_insert",
          "movies_profile_integrity_update",
          "series_profile_integrity_insert",
          "series_profile_integrity_update",
          "requests_profile_integrity_insert",
          "requests_profile_integrity_update",
          "media_profiles_references_integrity_update"
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger}")
    end
  end
end
