defmodule Cinder.Repo.Migrations.CreateAdminAudit do
  use Ecto.Migration

  # Records every destructive admin action (who/what/when). `detail` is an Ecto :map
  # stored as JSON TEXT by ecto_sqlite3. Append-only: rows are immutable (inserted_at
  # only, no updated_at). actor_id nilifies on user delete so the trail outlives the actor.
  def change do
    create table(:admin_audit) do
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :integer
      add :detail, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:admin_audit, [:actor_id])
    create index(:admin_audit, [:entity_type, :entity_id])
  end
end
