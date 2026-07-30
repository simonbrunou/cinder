defmodule Cinder.Disk do
  @moduledoc """
  Free/total disk-space gauge for a filesystem path. Backs the periodic `[:cinder, :disk]`
  telemetry measurement (`CinderWeb.Telemetry`) and the `/dashboard` disk cards.

  Reads `:disksup.get_disk_info/1` (OTP `os_mon`, listed in `extra_applications`) rather than
  shelling out and parsing `df` by hand. `:disksup` reports KiB — the same 1024-byte units the
  previous `df -kP` parser read — so callers see identical byte values.
  """

  @behaviour Cinder.Disk.Prober

  @type stats :: %{free_bytes: non_neg_integer(), total_bytes: non_neg_integer()}

  # Headroom that must stay free BEYOND the release itself before a poller hands it to a download
  # client. A false "insufficient" would strand a title (its download never starts), so the guards
  # fail OPEN on any uncertainty — an unknown release size, no configured root, or an unreadable
  # `df` all allow the grab. They skip only on positive evidence that no download root can hold it.
  @grab_margin_bytes 2 * 1024 * 1024 * 1024

  # Minimum free space on a library root before an import stages into it. A same-filesystem hardlink
  # costs ~nothing, but a cross-device import copies the whole file; a small fixed floor is a cheap
  # proxy for "don't stage into a nearly-full disk" without probing device boundaries per import.
  @import_floor_bytes 1 * 1024 * 1024 * 1024

  @doc """
  Reads free/total bytes for `path`. Returns `{:error, :enoent}` when `path` isn't a
  directory, `{:error, :unreadable}` when `:disksup` can't read the disk, and never raises.
  """
  @spec stats(String.t()) :: {:ok, stats()} | {:error, term()}
  def stats(path) when is_binary(path) do
    if File.dir?(path) do
      disk_info(path)
    else
      {:error, :enoent}
    end
  end

  # `:disksup.get_disk_info/1` reports `[{id, total_kib, available_kib, capacity}]` in KiB —
  # the same 1024-byte blocks the old `df -kP` parser read. A path it can't read (or an
  # os_mon that isn't running) comes back zeroed rather than as an error, so an all-zero row
  # maps to `{:error, :unreadable}` — the space guards fail open on any error.
  defp disk_info(path) do
    case :disksup.get_disk_info(String.to_charlist(path)) do
      [{_id, total_kib, avail_kib, _capacity}] when total_kib > 0 ->
        {:ok, %{free_bytes: avail_kib * 1024, total_bytes: total_kib * 1024}}

      _zeroed_or_unexpected ->
        {:error, :unreadable}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Whether a download of `size_bytes` can be placed on a configured download root with
  `@grab_margin_bytes` headroom to spare. Fails OPEN (returns `true`, allow the grab) for an
  unknown size, when no download root is configured, or when a root's free space can't be read —
  a probe glitch must never strand a title. Returns `false` only when every readable download
  root positively lacks room.
  """
  @spec grab_space_available?(non_neg_integer() | nil) :: boolean()
  def grab_space_available?(size_bytes) when is_integer(size_bytes) and size_bytes > 0 do
    roots_admit?(Cinder.Settings.import_roots(), size_bytes + @grab_margin_bytes)
  end

  def grab_space_available?(_size_bytes), do: true

  # Allow unless we have positive evidence NO readable root can hold `needed` — an unreadable root
  # (a df error) is treated as "might have room" so a probe glitch never blocks.
  defp roots_admit?([], _needed), do: true

  defp roots_admit?(roots, needed) do
    Enum.any?(roots, fn root ->
      case prober().stats(root) do
        {:ok, %{free_bytes: free}} -> free >= needed
        {:error, _reason} -> true
      end
    end)
  end

  @doc """
  Whether the `kind` (`:movies`/`:tv`) library root has at least `@import_floor_bytes` free before
  an import stages into it. Fails OPEN (returns `true`) for an unconfigured root (the importer
  already holds those) or an unreadable one (a probe glitch must not block a good import). Returns
  `false` only on positive evidence the root is below the floor.
  """
  @spec import_space_available?(atom()) :: boolean()
  def import_space_available?(kind) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      path when is_binary(path) and path != "" ->
        case prober().stats(path) do
          {:ok, %{free_bytes: free}} -> free >= @import_floor_bytes
          {:error, _reason} -> true
        end

      _unconfigured ->
        true
    end
  end

  @doc "Bytes as a rounded decimal-GB number, for human-facing log lines."
  @spec human_gb(non_neg_integer()) :: float()
  def human_gb(bytes) when is_integer(bytes), do: Float.round(bytes / 1_000_000_000, 1)

  defp prober, do: Application.get_env(:cinder, :disk_prober, __MODULE__)

  @doc """
  The configured library roots as `{kind, path}` pairs (`Cinder.Library.kinds/0`), skipping
  any kind whose path setting is unset or blank.
  """
  @spec configured_roots() :: [{atom(), String.t()}]
  def configured_roots do
    for kind <- Cinder.Library.kinds(),
        path = Application.get_env(:cinder, :"#{kind}_library_path"),
        path not in [nil, ""] do
      {kind, path}
    end
  end

  @doc """
  Every filesystem the app watches for free space, as `{kind, path}` pairs: the configured
  library roots (`configured_roots/0`) plus the volume holding the SQLite database (`:database`,
  from `db_root/0`). The database volume is what fills silently — a full DB volume raises
  SQLITE_FULL on every write while the pollers' `isolate` swallows it — so it is monitored
  alongside the library roots the guards already watch.
  """
  @spec monitored_roots() :: [{atom(), String.t()}]
  def monitored_roots do
    case db_root() do
      nil -> configured_roots()
      path -> configured_roots() ++ [{:database, path}]
    end
  end

  @doc """
  The directory holding the SQLite database file (and its `-wal`/`-shm` siblings), derived from
  the resolved Repo config exactly as the Repo opened it — `DATABASE_PATH` in prod, the dev/test
  fallback otherwise. `nil` when no database path is configured.
  """
  @spec db_root() :: String.t() | nil
  def db_root do
    case Application.get_env(:cinder, Cinder.Repo)[:database] do
      path when is_binary(path) and path != "" -> Path.dirname(path)
      _ -> nil
    end
  end

  @doc """
  Free bytes on the database volume, read through the `:disk_prober` seam (so a fast health probe
  never touches the real disks under test). `{:error, reason}` when the path is unknown or unreadable — a
  caller must fail OPEN on error, never treating a probe glitch as a low-space verdict.
  """
  @spec db_free_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def db_free_bytes do
    case db_root() do
      nil ->
        {:error, :no_database_path}

      root ->
        case prober().stats(root) do
          {:ok, %{free_bytes: free}} -> {:ok, free}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Disk stats for every monitored root (`monitored_roots/0`: library roots + the database volume).
  One row per root: `%{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}`.
  """
  @spec check_all() :: [
          %{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}
        ]
  def check_all do
    for {kind, path} <- monitored_roots() do
      %{kind: kind, path: path, status: stats(path)}
    end
  end
end
