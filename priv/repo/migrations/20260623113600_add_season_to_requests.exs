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
             name: :requests_pending_unique,
             where: "status = 'pending'"
           )
  end

  def down do
    # Drop whichever name the up/0 created (handles both old and new name variants)
    execute "DROP INDEX IF EXISTS requests_pending_unique"
    execute "DROP INDEX IF EXISTS requests_user_target_season_index"

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
