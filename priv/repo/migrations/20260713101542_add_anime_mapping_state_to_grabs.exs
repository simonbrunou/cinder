defmodule Cinder.Repo.Migrations.AddAnimeMappingStateToGrabs do
  use Ecto.Migration

  def change do
    alter table(:grabs) do
      add :mapping_snapshot, :map
      add :mapping_status, :string, null: false, default: "resolved"
      add :automatic_mapping_decisions, :map
      add :manual_mapping_overrides, :map
      add :mapping_issue, :map
    end
  end
end
