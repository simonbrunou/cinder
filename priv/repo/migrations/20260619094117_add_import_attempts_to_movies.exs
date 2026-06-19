defmodule Cinder.Repo.Migrations.AddImportAttemptsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :import_attempts, :integer, null: false, default: 0
    end
  end
end
