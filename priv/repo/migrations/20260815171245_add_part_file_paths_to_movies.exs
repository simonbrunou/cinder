defmodule Cinder.Repo.Migrations.AddPartFilePathsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :part_file_paths, {:array, :string}, default: [], null: false
    end
  end
end
