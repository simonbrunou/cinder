defmodule Cinder.Repo.Migrations.AddMediaServerItemIds do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :media_server_item_id, :string
    end

    alter table(:series) do
      add :media_server_item_id, :string
    end
  end
end
