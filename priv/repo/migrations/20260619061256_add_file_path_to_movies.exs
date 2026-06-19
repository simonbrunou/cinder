defmodule Cinder.Repo.Migrations.AddFilePathToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :file_path, :string
    end
  end
end
