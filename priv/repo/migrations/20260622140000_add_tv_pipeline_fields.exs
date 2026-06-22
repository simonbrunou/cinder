defmodule Cinder.Repo.Migrations.AddTvPipelineFields do
  use Ecto.Migration

  # M5a: the grab/download record (one download → N episodes) + the per-episode
  # pipeline fields. Additive — the movie loop is untouched. Episodes stay status-less:
  # state is derived (file_path ⇒ available, grab_id ⇒ downloading, else wanted). A grab's
  # phase is derived from content_path (nil ⇒ downloading, set ⇒ ready to import).
  def change do
    create table(:grabs) do
      add :download_id, :string, null: false
      add :download_protocol, :string, null: false
      add :content_path, :string
      add :download_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    alter table(:episodes) do
      add :file_path, :string
      add :grab_id, references(:grabs, on_delete: :nilify_all)
      add :search_attempts, :integer, null: false, default: 0
      add :import_attempts, :integer, null: false, default: 0
    end

    create index(:episodes, [:grab_id])
  end
end
