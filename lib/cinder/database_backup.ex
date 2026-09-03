defmodule Cinder.DatabaseBackup do
  @moduledoc """
  Creates verified online SQLite snapshots and keeps the newest scheduled copies.

  Scheduled snapshots live under `backups/` beside the database, are mode 0600, and are only
  published after `PRAGMA integrity_check` succeeds. The daily worker is stateless, so a failed
  pass simply retries on its next tick.
  """
  require Logger

  alias Cinder.{Disk, Repo}
  alias Exqlite.Sqlite3

  @default_interval :timer.hours(24)
  @default_retention 7
  @prefix "cinder-backup-"

  use Cinder.Download.PollerSkeleton,
    log_prefix: "database backup",
    stateful: false,
    first_interval: :timer.minutes(1)

  @doc "Creates a verified snapshot at `path`, removing it on any failure."
  @spec create(String.t()) :: :ok | {:error, term()}
  def create(path) when is_binary(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> reserve_and_create(path)
      {:error, _reason} = error -> log_snapshot_error(error)
    end
  end

  @doc "Creates a verified private snapshot for the admin download endpoint."
  @spec temporary_snapshot() :: {:ok, String.t()} | {:error, term()}
  def temporary_snapshot do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    path = Path.join(Disk.db_root() || System.tmp_dir!(), ".cinder-snapshot-#{token}.sqlite3")

    case create(path) do
      :ok -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  @doc "Deletes a temporary snapshot. Missing files are already clean."
  @spec cleanup(String.t()) :: :ok | {:error, File.posix()}
  def cleanup(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Opens a snapshot independently and requires SQLite's full integrity check to pass."
  @spec verify(String.t()) :: :ok | {:error, term()}
  def verify(path) do
    with {:ok, database} <- Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, statement} <- Sqlite3.prepare(database, "PRAGMA integrity_check") do
          try do
            case Sqlite3.fetch_all(database, statement) do
              {:ok, [["ok"]]} -> :ok
              {:ok, rows} -> {:error, {:integrity_check_failed, rows}}
              {:error, _reason} = error -> error
            end
          after
            Sqlite3.release(database, statement)
          end
        end
      after
        Sqlite3.close(database)
      end
    end
  end

  @doc "Creates one scheduled snapshot and prunes older owned snapshots after success."
  @spec create_scheduled() :: {:ok, String.t()} | {:error, term()}
  def create_scheduled do
    path = Path.join(backup_dir(), scheduled_filename())

    case ensure_backup_dir() do
      :ok -> create_and_prune(path)
      {:error, _reason} = error -> log_snapshot_error(error)
    end
  end

  @doc "Configured scheduled-backup directory."
  @spec backup_dir() :: String.t()
  def backup_dir do
    config()
    |> Keyword.get(:backup_dir)
    |> case do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(Disk.db_root() || System.tmp_dir!(), "backups")
    end
  end

  @doc "Maximum number of scheduled snapshots kept on disk."
  @spec retention() :: pos_integer()
  def retention do
    case Keyword.get(config(), :retention, @default_retention) do
      count when is_integer(count) and count > 0 -> count
      _ -> @default_retention
    end
  end

  defp do_poll do
    case create_scheduled() do
      {:ok, path} -> Logger.info("database backup created: #{path}")
      {:error, _reason} -> :ok
    end
  end

  defp reserve(path) do
    case File.write(path, <<>>, [:exclusive]) do
      :ok ->
        case File.chmod(path, 0o600) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            cleanup(path)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp reserve_and_create(path) do
    case reserve(path) do
      :ok -> create_reserved(path)
      {:error, _reason} = error -> log_snapshot_error(error)
    end
  end

  defp create_reserved(path) do
    with {:ok, _result} <- Repo.query("VACUUM INTO ?", [path], timeout: :infinity),
         :ok <- verify(path) do
      :ok
    else
      {:error, _reason} = error ->
        cleanup(path)
        log_snapshot_error(error)
    end
  end

  defp ensure_backup_dir do
    with :ok <- File.mkdir_p(backup_dir()), do: File.chmod(backup_dir(), 0o700)
  end

  defp create_and_prune(path) do
    pending = pending_path()

    case create(pending) do
      :ok ->
        publish_and_prune(pending, path)

      {:error, _reason} = error ->
        error
    end
  end

  defp publish_and_prune(pending, path) do
    case File.ln(pending, path) do
      :ok ->
        cleanup_pending(pending)
        prune()
        {:ok, path}

      {:error, _reason} = error ->
        cleanup_pending(pending)
        log_snapshot_error(error)
    end
  end

  defp cleanup_pending(path) do
    case cleanup(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("database backup temporary cleanup failed: #{inspect(reason)}")
    end
  end

  defp log_snapshot_error({:error, reason} = error) do
    Logger.error("database snapshot failed: #{inspect(reason)}")
    error
  end

  defp prune do
    backup_dir()
    |> Path.join("#{@prefix}*.sqlite3")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.drop(retention())
    |> Enum.each(fn path ->
      case cleanup(path) do
        :ok -> :ok
        {:error, reason} -> Logger.error("database backup prune failed: #{inspect(reason)}")
      end
    end)

    prune_pending_files()
  end

  defp prune_pending_files do
    backup_dir()
    |> Path.join(".cinder-backup-pending-*.sqlite3")
    |> Path.wildcard()
    |> Enum.each(&prune_pending_if_stale/1)
  end

  defp prune_pending_if_stale(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> maybe_cleanup_stale_pending(path, stat)
      {:error, reason} -> Logger.error("database backup pending stat failed: #{inspect(reason)}")
    end
  end

  defp maybe_cleanup_stale_pending(path, stat) do
    interval =
      Keyword.get(config(), :interval, @default_interval)

    now_seconds = System.os_time(:second)
    mtime_seconds = stat.mtime

    if now_seconds - mtime_seconds > div(interval, 1000) do
      case cleanup(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("database backup pending cleanup failed: #{inspect(reason)}")
      end
    end
  end

  defp scheduled_filename do
    @prefix <> Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S%fZ") <> ".sqlite3"
  end

  defp pending_path do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(backup_dir(), ".cinder-backup-pending-#{token}.sqlite3")
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
