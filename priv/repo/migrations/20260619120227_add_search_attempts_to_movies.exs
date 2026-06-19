defmodule Cinder.Repo.Migrations.AddSearchAttemptsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :search_attempts, :integer, default: 0, null: false
    end
  end
end
