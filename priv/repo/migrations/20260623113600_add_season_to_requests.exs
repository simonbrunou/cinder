defmodule Cinder.Repo.Migrations.AddSeasonToRequests do
  use Ecto.Migration

  def up do
    alter table(:requests) do
      add :season_number, :integer
    end

    execute "DROP INDEX IF EXISTS requests_pending_unique"

    create unique_index(
             :requests,
             [:user_id, :target_type, :target_id, "COALESCE(season_number, -1)"],
             name: :requests_user_target_season_index,
             where: "status != 'denied'"
           )
  end

  def down do
    drop index(:requests, name: :requests_user_target_season_index)

    execute """
    CREATE UNIQUE INDEX requests_pending_unique
    ON requests (user_id, target_type, target_id)
    WHERE status = 'pending'
    """

    alter table(:requests) do
      remove :season_number
    end
  end
end
