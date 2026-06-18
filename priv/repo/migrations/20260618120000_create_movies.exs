defmodule Cinder.Repo.Migrations.CreateMovies do
  use Ecto.Migration

  def change do
    create table(:movies) do
      add :tmdb_id, :integer, null: false
      add :title, :string, null: false
      add :year, :integer
      add :poster_path, :string
      add :status, :string, null: false, default: "requested"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:movies, [:tmdb_id])
  end
end
