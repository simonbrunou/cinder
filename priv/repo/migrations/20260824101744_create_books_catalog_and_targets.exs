defmodule Cinder.Repo.Migrations.CreateBooksCatalogAndTargets do
  use Ecto.Migration

  def change do
    create table(:book_authors) do
      add :name, :string, null: false
      add :sort_name, :string
      add :disambiguation, :string
      timestamps(type: :utc_datetime)
    end

    create table(:book_works) do
      add :title, :string, null: false
      add :original_title, :string
      add :first_published_on, :date
      add :overview, :text
      add :contributors_incomplete, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create table(:book_editions) do
      add :work_id, references(:book_works, on_delete: :delete_all), null: false
      add :media_kind, :string, null: false
      add :title, :string, null: false
      add :language, :string
      add :format, :string
      add :publisher, :string
      add :release_date, :date
      add :abridged, :boolean
      timestamps(type: :utc_datetime)
    end

    create table(:book_identifiers) do
      add :author_id, references(:book_authors, on_delete: :delete_all),
        check: %{
          name: "book_identifiers_one_subject",
          expr: "(author_id IS NOT NULL) + (work_id IS NOT NULL) + (edition_id IS NOT NULL) = 1"
        }

      add :work_id, references(:book_works, on_delete: :delete_all)
      add :edition_id, references(:book_editions, on_delete: :delete_all)
      add :provider, :string, null: false
      add :kind, :string, null: false
      add :foreign_id, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:book_identifiers, [:provider, :kind, :foreign_id])

    create table(:book_credits) do
      add :author_id, references(:book_authors, on_delete: :delete_all), null: false

      add :work_id, references(:book_works, on_delete: :delete_all),
        check: %{
          name: "book_credits_one_subject",
          expr:
            "(work_id IS NOT NULL AND edition_id IS NULL) OR " <>
              "(work_id IS NULL AND edition_id IS NOT NULL)"
        }

      add :edition_id, references(:book_editions, on_delete: :delete_all)
      add :role, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:book_credits, [:work_id, :author_id, :role])
    create unique_index(:book_credits, [:edition_id, :author_id, :role])

    # ponytail: Flat rows until series need pages/provider identity; then promote to book_series.
    create table(:book_series_memberships) do
      add :work_id, references(:book_works, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :string
      add :provider, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:book_targets) do
      add :work_id, references(:book_works, on_delete: :delete_all), null: false

      add :media_kind, :string,
        null: false,
        check: %{
          name: "book_targets_media_kind_valid",
          expr: "media_kind IN ('ebook', 'audiobook')"
        }

      add :status, :string,
        null: false,
        default: "unmonitored",
        check: %{
          name: "book_targets_status_valid",
          expr: "status IN ('unmonitored', 'monitored', 'available', 'held')"
        }

      add :profile_id, references(:media_profiles, on_delete: :restrict)
      add :hold_reason, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:book_targets, [:work_id, :media_kind])

    for event <- ["INSERT", "UPDATE OF profile_id, media_kind"] do
      suffix = if event == "INSERT", do: "insert", else: "update"
      name = "book_targets_profile_integrity_#{suffix}"

      execute(
        """
        CREATE TRIGGER #{name}
        BEFORE #{event} ON book_targets
        WHEN NEW.profile_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM media_profiles
          WHERE id = NEW.profile_id
            AND kind = NEW.media_kind
        )
        BEGIN
          SELECT RAISE(ABORT, 'CHECK constraint failed: book_targets_profile_integrity');
        END
        """,
        "DROP TRIGGER #{name}"
      )
    end

    execute(
      "DROP TRIGGER media_profiles_references_integrity_update",
      """
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
      """
    )

    execute(
      """
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
        ) OR
        EXISTS (
          SELECT 1 FROM book_targets
          WHERE profile_id = OLD.id
            AND NEW.kind != media_kind
        )
      BEGIN
        SELECT RAISE(ABORT, 'CHECK constraint failed: media_profiles_references_integrity');
      END
      """,
      "DROP TRIGGER media_profiles_references_integrity_update"
    )
  end
end
