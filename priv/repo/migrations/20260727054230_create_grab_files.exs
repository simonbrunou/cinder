defmodule Cinder.Repo.Migrations.CreateGrabFiles do
  use Ecto.Migration

  def change do
    create table(:grab_files) do
      add :grab_id, references(:grabs, on_delete: :delete_all), null: false
      add :relative_path, :string, null: false
      add :size, :integer, null: false
      add :device, :integer, null: false
      add :inode, :integer, null: false
      add :source, :string
      add :scheme, :string
      add :namespace, :string
      add :canonical_value, :string
      add :episode_id, references(:episodes, on_delete: :nilify_all)
      add :decision, :string
      add :destination, :string
      add :import_stage_id, references(:import_stages, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:grab_files, [:grab_id, :relative_path])
    create unique_index(:grab_files, [:grab_id, :device, :inode])
    create index(:grab_files, [:episode_id])
    create index(:grab_files, [:import_stage_id])
  end
end
