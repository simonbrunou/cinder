defmodule Cinder.Repo.Migrations.AddActiveToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :active, :boolean, null: false, default: true
    end

    execute("UPDATE users SET active = 1")
  end

  def down do
    alter table(:users) do
      remove :active
    end
  end
end
