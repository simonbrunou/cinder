defmodule Cinder.Repo.Migrations.AddDownloadProtocolToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      # Backed by Ecto.Enum (:torrent | :usenet). Nullable, no default, no
      # backfill: rows in-flight at upgrade are all torrents, and client_for/1
      # resolves nil -> :torrent.
      add :download_protocol, :string
    end
  end
end
