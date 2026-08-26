defmodule Cinder.Repo.Migrations.PreventDuplicateActiveRequests do
  use Ecto.Migration

  def up do
    ensure_no_duplicate_active_requests!()

    execute "DROP INDEX IF EXISTS requests_pending_unique"

    create unique_index(
             :requests,
             [
               :user_id,
               :target_type,
               :target_id,
               "COALESCE(season_number, -1)",
               "COALESCE(media_kind, '')"
             ],
             # Keep the historical name: Request changesets match SQLite violations by it.
             name: :requests_pending_unique,
             where: "status IN ('pending', 'approved')"
           )
  end

  def down do
    execute "DROP INDEX IF EXISTS requests_pending_unique"

    create unique_index(
             :requests,
             [
               :user_id,
               :target_type,
               :target_id,
               "COALESCE(season_number, -1)",
               "COALESCE(media_kind, '')"
             ],
             name: :requests_pending_unique,
             where: "status = 'pending'"
           )
  end

  defp ensure_no_duplicate_active_requests! do
    case repo().query!("""
         SELECT
           user_id,
           target_type,
           target_id,
           COALESCE(season_number, -1),
           COALESCE(media_kind, ''),
           COUNT(*)
         FROM requests
         WHERE status IN ('pending', 'approved')
         GROUP BY
           user_id,
           target_type,
           target_id,
           COALESCE(season_number, -1),
           COALESCE(media_kind, '')
         HAVING COUNT(*) > 1
         LIMIT 1
         """).rows do
      [] ->
        :ok

      [[user_id, target_type, target_id, season_number, media_kind, count]] ->
        raise """
        cannot enforce active request uniqueness: found #{count} pending or approved rows for \
        user_id=#{user_id}, target_type=#{inspect(target_type)}, target_id=#{target_id}, \
        season_number=#{season_number}, media_kind=#{inspect(media_kind)}; resolve the duplicate \
        request history and retry the migration
        """
    end
  end
end
