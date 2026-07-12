defmodule Cinder.Repo.Migrations.CreateImportStages do
  use Ecto.Migration

  def change do
    create table(:import_stages) do
      add :operation_key, :string, null: false
      add :state, :string, null: false, default: "preparing"
      add :root, :string, null: false
      add :dest, :string, null: false
      add :candidate, :string, null: false
      add :backup, :string
      add :candidate_inode, :integer
      add :candidate_device, :integer
      add :candidate_size, :integer
      add :staged_inode, :integer
      add :staged_device, :integer
      add :staged_size, :integer
      add :backup_inode, :integer
      add :backup_device, :integer
      add :backup_size, :integer
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_stages, [:operation_key])
    create index(:import_stages, [:state])
  end
end
