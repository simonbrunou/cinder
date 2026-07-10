defmodule Cinder.Repo.Migrations.AddDownloadProgressMetrics do
  use Ecto.Migration

  def change do
    for table <- [:movies, :grabs] do
      alter table(table) do
        add :download_progress, :float
        add :download_speed, :integer
        add :download_eta, :integer
      end
    end
  end
end
