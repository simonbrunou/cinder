defmodule Cinder.Repo.Migrations.DropEpisodeImportAttempts do
  use Ecto.Migration

  # `episodes.import_attempts` was copy-pasted from the Movie schema but never read or written:
  # an episode's post-download retry budget lives on the grab (`grabs.download_attempts`), and the
  # re-search budget on `episodes.search_attempts`. Drop the dead column. (SQLite 3.35+ / the
  # bundled engine supports ALTER TABLE … DROP COLUMN.)
  # Execute immediately through the checked-out connection. Queuing DROP COLUMN through the
  # migration runner fails on a fresh release database even though table_xinfo reports the column.
  def up do
    if column?("import_attempts") do
      Ecto.Adapters.SQL.query!(repo(), "ALTER TABLE episodes DROP COLUMN import_attempts")
    end
  end

  def down do
    unless column?("import_attempts") do
      Ecto.Adapters.SQL.query!(
        repo(),
        "ALTER TABLE episodes ADD COLUMN import_attempts INTEGER NOT NULL DEFAULT 0"
      )
    end
  end

  defp column?(name) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo(), "PRAGMA table_xinfo(episodes)")
    Enum.any?(rows, &(Enum.at(&1, 1) == name))
  end
end
