defmodule Cinder.Repo.Migrations.CreateSubtitleShotChanges do
  use Ecto.Migration

  # Spec 069 (option B): subtitle timing snaps to shot changes, and finding them decodes the whole
  # video (minutes of CPU per episode). The result is cached per video, keyed by its moviehash, so
  # a re-sync, a reset or a later explicit request never decodes the same file twice.
  def change do
    create table(:subtitle_shot_changes) do
      add :moviehash, :string, null: false
      add :times_ms, {:array, :integer}, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitle_shot_changes, [:moviehash])
  end
end
