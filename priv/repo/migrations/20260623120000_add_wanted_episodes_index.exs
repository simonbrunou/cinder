defmodule Cinder.Repo.Migrations.AddWantedEpisodesIndex do
  use Ecto.Migration

  # M6: partial index backing Catalog.wanted_episodes/0. The monitored, file-less, grab-less,
  # aired set is a small slice of episodes, so a partial index on air_date is exactly what the
  # poller's per-tick sweep wants — no full episodes scan. (ecto_sqlite3 stores booleans as 1/0,
  # hence `monitored = 1`.)
  def change do
    create index(:episodes, [:air_date],
             where: "file_path IS NULL AND grab_id IS NULL AND monitored = 1",
             name: :episodes_wanted_index
           )
  end
end
