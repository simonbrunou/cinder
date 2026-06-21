defmodule Cinder.Repo.Migrations.CreateRequests do
  use Ecto.Migration

  def change do
    create table(:requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :target_type, :string, null: false
      add :target_id, :integer, null: false
      add :title, :string
      add :year, :integer
      add :poster_path, :string
      add :status, :string, null: false, default: "pending"
      add :denial_reason, :string
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create index(:requests, [:user_id])
    create index(:requests, [:status])

    create unique_index(:requests, [:user_id, :target_type, :target_id],
             where: "status = 'pending'",
             name: :requests_pending_unique
           )
  end
end
