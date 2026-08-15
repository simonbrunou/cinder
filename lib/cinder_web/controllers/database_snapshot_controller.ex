defmodule CinderWeb.DatabaseSnapshotController do
  @moduledoc "Admin-only download of a consistent online SQLite database snapshot."
  use CinderWeb, :controller

  alias Cinder.DatabaseBackup

  def download(conn, _params) do
    case DatabaseBackup.temporary_snapshot() do
      {:ok, path} ->
        try do
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_download({:file, path},
            filename: "cinder-backup-#{Date.utc_today()}.sqlite3",
            content_type: "application/vnd.sqlite3"
          )
        after
          DatabaseBackup.cleanup(path)
        end

      {:error, reason} ->
        snapshot_error(conn, reason)
    end
  end

  defp snapshot_error(conn, _reason) do
    conn
    |> put_flash(:error, gettext("The database backup could not be created. Please try again."))
    |> redirect(to: ~p"/settings")
  end
end
