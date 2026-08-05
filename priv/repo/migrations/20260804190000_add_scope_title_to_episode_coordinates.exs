defmodule Cinder.Repo.Migrations.AddScopeTitleToEpisodeCoordinates do
  use Ecto.Migration

  def change do
    alter table(:episode_coordinates) do
      add :scope_title, :string
    end
  end
end
