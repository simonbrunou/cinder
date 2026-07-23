defmodule Cinder.Repo.Migrations.AddLocalizationsToMoviesAndSeries do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :localizations, :map, default: %{}
    end

    alter table(:series) do
      add :localizations, :map, default: %{}
    end
  end
end
