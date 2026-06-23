defmodule Cinder.Repo.Migrations.DropEpisodeImportAttempts do
  use Ecto.Migration

  # `episodes.import_attempts` was copy-pasted from the Movie schema but never read or written:
  # an episode's post-download retry budget lives on the grab (`grabs.download_attempts`), and the
  # re-search budget on `episodes.search_attempts`. Drop the dead column. (SQLite 3.35+ / the
  # bundled engine supports ALTER TABLE … DROP COLUMN.)
  # The `remove/3` opts are reused to recreate the column on rollback, so mirror the original add
  # (20260622140000, `null: false, default: 0`) exactly — otherwise a rollback restores it nullable.
  def change do
    alter table(:episodes) do
      remove :import_attempts, :integer, null: false, default: 0
    end
  end
end
