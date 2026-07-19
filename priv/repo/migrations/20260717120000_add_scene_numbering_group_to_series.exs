defmodule Cinder.Repo.Migrations.AddSceneNumberingGroupToSeries do
  use Ecto.Migration

  def change do
    alter table(:series), do: add(:scene_numbering_group_id, :string)
  end
end
