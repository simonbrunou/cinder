defmodule Cinder.Repo.Migrations.AddDownloadFieldsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :imdb_id, :string
      add :download_id, :string
    end
  end
end
