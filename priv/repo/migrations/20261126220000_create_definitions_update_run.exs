defmodule Cinder.Repo.Migrations.CreateDefinitionsUpdateRun do
  use Ecto.Migration

  # The last run of the indexer definitions update job (#1669): one row, id 1, overwritten by
  # each run. Only `Cinder.Indexers.Definitions.Updater` writes this table.
  def change do
    create table(:definitions_update_run, primary_key: false) do
      add :id, :integer, primary_key: true
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime, null: false
      add :outcome, :string, null: false
      # The commit the run saw upstream; NULL when the fetch failed.
      add :commit, :string
      # The failed run's closed error tag as an Erlang term; NULL for any other outcome.
      add :error, :binary
      add :last_success_at, :utc_datetime
      # The first failure since the last success; a success clears it.
      add :first_failure_at, :utc_datetime
    end
  end
end
