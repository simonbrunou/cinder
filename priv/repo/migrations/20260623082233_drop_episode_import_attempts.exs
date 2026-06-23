defmodule Cinder.Repo.Migrations.DropEpisodeImportAttempts do
  use Ecto.Migration

  # `episodes.import_attempts` was copy-pasted from the Movie schema but never read or written:
  # an episode's post-download retry budget lives on the grab (`grabs.download_attempts`), and the
  # re-search budget on `episodes.search_attempts`. Drop the dead column. (SQLite 3.35+ / the
  # bundled engine supports ALTER TABLE … DROP COLUMN.)
  def change do
    alter table(:episodes) do
      remove :import_attempts, :integer, default: 0
    end
  end
end
