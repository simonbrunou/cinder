defmodule Cinder.Repo.Migrations.CreateTvSchema do
  use Ecto.Migration

  # M4a: the Series → Season → Episode tree, behind monitoring flags. Purely
  # additive — the movie loop is untouched. Episodes carry identity + monitoring
  # only; the download/import pipeline fields land in M5 with the TV poller (and
  # the grab/download join table that owns the download id/protocol).
  def change do
    create table(:series) do
      add :tmdb_id, :integer, null: false
      add :tvdb_id, :integer
      add :title, :string, null: false
      add :year, :integer
      add :poster_path, :string
      add :monitored, :boolean, null: false, default: true
      add :monitor_strategy, :string, null: false, default: "future"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series, [:tmdb_id])

    create table(:seasons) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :season_number, :integer, null: false
      add :monitored, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:seasons, [:series_id])
    create unique_index(:seasons, [:series_id, :season_number])

    create table(:episodes) do
      add :season_id, references(:seasons, on_delete: :delete_all), null: false
      add :tmdb_episode_id, :integer
      add :episode_number, :integer, null: false
      add :title, :string
      add :air_date, :date
      add :monitored, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:episodes, [:season_id])
    create unique_index(:episodes, [:season_id, :episode_number])
  end
end
