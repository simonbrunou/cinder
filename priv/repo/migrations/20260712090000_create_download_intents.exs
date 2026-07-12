defmodule Cinder.Repo.Migrations.CreateDownloadIntents do
  use Ecto.Migration

  def change do
    create table(:download_intents) do
      add :operation_key, :string, null: false
      add :kind, :string, null: false
      add :target_id, :integer, null: false
      add :episode_ids, {:array, :integer}, null: false, default: []
      add :protocol, :string, null: false
      add :release, :map, null: false
      add :status, :string, null: false, default: "reserved"
      add :remote_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:download_intents, [:operation_key])
    create index(:download_intents, [:status])
  end
end
