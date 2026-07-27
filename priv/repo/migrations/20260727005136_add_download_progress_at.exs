defmodule Cinder.Repo.Migrations.AddDownloadProgressAt do
  use Ecto.Migration

  def change do
    for table <- [:movies, :grabs] do
      alter table(table) do
        add :download_progress_at, :utc_datetime
      end

      execute(
        "UPDATE #{table} SET download_progress_at = updated_at",
        "UPDATE #{table} SET download_progress_at = NULL"
      )
    end
  end
end
