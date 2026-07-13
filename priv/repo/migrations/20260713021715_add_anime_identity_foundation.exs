defmodule Cinder.Repo.Migrations.AddAnimeIdentityFoundation do
  use Ecto.Migration

  def change do
    alter table(:movies), do: add(:media_profile, :string, null: false, default: "auto")
    alter table(:series), do: add(:media_profile, :string, null: false, default: "auto")
    alter table(:requests), do: add(:proposed_media_profile, :string)

    alter table(:episodes) do
      add :classification, :string, null: false, default: "regular"
      add :classification_source, :string, null: false, default: "legacy"
      add :classification_label, :string
    end

    create table(:title_aliases) do
      add :movie_id, references(:movies, on_delete: :delete_all),
        check: %{
          name: "title_aliases_exactly_one_owner",
          expr:
            "(movie_id IS NOT NULL AND series_id IS NULL) OR (movie_id IS NULL AND series_id IS NOT NULL)"
        }

      add :series_id, references(:series, on_delete: :delete_all)
      add :title, :string, null: false
      add :normalized_title, :string, null: false
      add :country_code, :string
      add :language_code, :string
      add :kind, :string, null: false, default: "alternative"
      add :source, :string, null: false
      add :namespace, :string, null: false
      add :precedence, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:title_aliases, [:movie_id, :source, :namespace, :normalized_title],
             where: "movie_id IS NOT NULL",
             name: :title_aliases_movie_source_unique
           )

    create unique_index(:title_aliases, [:series_id, :source, :namespace, :normalized_title],
             where: "series_id IS NOT NULL",
             name: :title_aliases_series_source_unique
           )

    create table(:episode_coordinates) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :scheme, :string, null: false
      add :namespace, :string, null: false
      add :canonical_value, :string, null: false
      add :precedence, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :episode_coordinates,
             [:series_id, :source, :scheme, :namespace, :canonical_value],
             name: :episode_coordinates_identity_unique
           )

    create table(:episode_coordinate_memberships) do
      add :episode_coordinate_id, references(:episode_coordinates, on_delete: :delete_all),
        null: false

      add :episode_id, references(:episodes, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :episode_coordinate_memberships,
             [:episode_coordinate_id, :episode_id],
             name: :coordinate_membership_episode_unique
           )

    create unique_index(
             :episode_coordinate_memberships,
             [:episode_coordinate_id, :position],
             name: :coordinate_membership_position_unique
           )

    create index(:episode_coordinate_memberships, [:episode_id])
  end
end
