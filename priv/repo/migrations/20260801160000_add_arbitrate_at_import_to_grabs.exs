defmodule Cinder.Repo.Migrations.AddArbitrateAtImportToGrabs do
  use Ecto.Migration

  # Marks a grab whose episode swaps the IMPORT decides, per episode, instead of the grab forcing
  # them (#250). Default false so grabs already in flight when this runs keep forcing, which is
  # what every pre-existing grab was created under.
  def change do
    alter table(:grabs) do
      add :arbitrate_at_import, :boolean, null: false, default: false
    end
  end
end
