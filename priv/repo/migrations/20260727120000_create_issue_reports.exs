defmodule Cinder.Repo.Migrations.CreateIssueReports do
  use Ecto.Migration

  def change do
    create table(:issue_reports) do
      # Mirrors requests' GDPR handling: a user deletion cascades away their reports.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Polymorphic target, mirroring requests (movie tmdb_id, or a series tmdb_id + season_number).
      add :target_type, :string, null: false
      add :target_id, :integer, null: false
      add :season_number, :integer
      # Title snapshot (like requests carry) so the admin queue renders without a catalog join and
      # survives the underlying movie/series being deleted.
      add :title, :string
      add :category, :string, null: false
      add :detail, :string
      add :status, :string, null: false, default: "open"
      # The admin who resolved/dismissed it; nilify (not cascade) so their deletion keeps the record.
      add :resolver_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create index(:issue_reports, [:user_id])
    create index(:issue_reports, [:status])
  end
end
