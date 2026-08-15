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
  end

  def down do
    drop index(:requests, [:proposed_profile_id])
    drop index(:series, [:profile_id])
    drop index(:movies, [:profile_id])

    alter table(:requests), do: remove(:proposed_profile_id)
    alter table(:series), do: remove(:profile_id)
    alter table(:movies), do: remove(:profile_id)

    drop table(:media_profiles)
  end
end
