defmodule Cinder.Repo.Migrations.AddMappingSnapshotToDownloadIntents do
  use Ecto.Migration

  def change do
    alter table(:download_intents) do
      add :mapping_snapshot, :map
    end
  end
end
