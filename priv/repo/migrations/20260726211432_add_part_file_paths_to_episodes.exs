defmodule Cinder.Repo.Migrations.AddPartFilePathsToEpisodes do
  use Ecto.Migration

  def change do
    alter table(:episodes) do
      # A serialized list is enough: part paths are episode-owned and never queried independently.
      add :part_file_paths, {:array, :string}, null: false, default: []
    end
  end
end
