defmodule Cinder.Repo.Migrations.AddDownloadPausedAtToInFlightRows do
  use Ecto.Migration

  # #1598: when the download client paused this row's download. Nil means it is not paused. The
  # badge reads it, and the end of the pause takes the paused time off `download_progress_at`.
  def change do
    for table <- [:movies, :grabs, :book_grabs] do
      alter table(table) do
        add :download_paused_at, :utc_datetime
      end
    end
  end
end
