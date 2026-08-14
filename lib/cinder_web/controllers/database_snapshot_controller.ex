defmodule CinderWeb.DatabaseSnapshotController do
  @moduledoc "Admin-only download of a consistent online SQLite database snapshot."
  use CinderWeb, :controller

  require Logger

  alias Cinder.{Disk, Repo}

  def download(conn, _params) do
    path = snapshot_path()

    try do
      with :ok <- reserve(path),
           {:ok, _result} <- Repo.query("VACUUM INTO ?", [path], timeout: :infinity) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:file, path},
          filename: "cinder-backup-#{Date.utc_today()}.sqlite3",
          content_type: "application/vnd.sqlite3"
        )
      else
        {:error, reason} -> snapshot_error(conn, reason)
      end
    after
      cleanup(path)
    end
  end

  defp snapshot_path do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Disk.db_root() || System.tmp_dir!(), ".cinder-snapshot-#{token}.sqlite3")
  end

  defp reserve(path) do
    with :ok <- File.write(path, <<>>, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp snapshot_error(conn, reason) do
    Logger.error("database snapshot failed: #{inspect(reason)}")

    conn
    |> put_flash(:error, gettext("The database backup could not be created. Please try again."))
    |> redirect(to: ~p"/settings")
  end

  defp cleanup(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.error("database snapshot cleanup failed: #{inspect(reason)}")
    end
  end
end
