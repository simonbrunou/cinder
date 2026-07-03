defmodule Cinder.Repo.Migrations.AddMediaMetadata do
  use Ecto.Migration

  # Descriptive TMDB metadata for the per-title detail pages. Populated lazily on
  # first detail-view (Catalog.enrich_movie/enrich_series), and kept fresh for series
  # by the periodic refresh. genres is stored as JSON (ecto_sqlite3 {:array, :string}).
  def change do
    alter table(:movies) do
      add :overview, :text
      add :runtime, :integer
      add :genres, {:array, :string}
      add :vote_average, :float
      add :release_date, :date
    end

    alter table(:series) do
      add :overview, :text
      add :genres, {:array, :string}
      add :vote_average, :float
      add :first_air_date, :date
    end
  end
end
