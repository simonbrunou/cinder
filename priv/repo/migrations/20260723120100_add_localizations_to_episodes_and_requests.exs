defmodule Cinder.Repo.Migrations.AddLocalizationsToEpisodesAndRequests do
  use Ecto.Migration

  def change do
    alter table(:episodes) do
      add :localizations, :map, default: %{}
    end

    alter table(:requests) do
      add :localizations, :map, default: %{}
    end
  end
end
