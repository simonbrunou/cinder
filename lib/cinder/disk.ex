defmodule Cinder.Disk do
  @moduledoc """
  Free/total disk-space gauge for a filesystem path. Backs the periodic `[:cinder, :disk]`
  telemetry measurement (`CinderWeb.Telemetry`) and the `/dashboard` disk cards.

  Runs a path-scoped POSIX `df -kP` probe through an owned port. The subprocess is bounded so a
  hung filesystem degrades to an error instead of wedging every disk-space consumer. `df` reports
  1024-byte blocks, preserving the existing byte-value contract.
  """

  @behaviour Cinder.Disk.Prober

  @type stats :: %{free_bytes: non_neg_integer(), total_bytes: non_neg_integer()}

  # Headroom that must stay free BEYOND the release itself before a poller hands it to a download
  # client. A false "insufficient" would strand a title (its download never starts), so the guards
  # fail OPEN on any uncertainty — an unknown release size, no configured root, or an unreadable
  # `df` all allow the grab. They skip only on positive evidence that no download root can hold it.
  @grab_margin_bytes 2 * 1024 * 1024 * 1024
  @default_probe_timeout 2_000

  # Minimum free space on a library root before an import stages into it. A same-filesystem hardlink
  # costs ~nothing, but a cross-device import copies the whole file; a small fixed floor is a cheap
  # proxy for "don't stage into a nearly-full disk" without probing device boundaries per import.
  @import_floor_bytes 1 * 1024 * 1024 * 1024

  @doc """
  Reads free/total bytes for `path`. Returns `{:error, :enoent}` when `path` isn't a
  directory, `{:error, :unreadable}` when `df` returns malformed output, and never raises.
  """
  @spec stats(String.t()) :: {:ok, stats()} | {:error, term()}
  def stats(path) when is_binary(path) do
    if File.dir?(path) do
      disk_info(path)
    else
      {:error, :enoent}
    end
  end

  # POSIX `df -kP path` scopes each subprocess to the one filesystem the caller needs, unlike
  # `:disksup`, whose process-wide scan can wedge forever on one unrelated hung mount. Owning the
  # port directly lets the timeout path kill and reap the OS process instead of orphaning it.
  defp disk_info(path) do
    timeout = Application.get_env(:cinder, :disk_probe_timeout, @default_probe_timeout)

    with {:ok, port} <- open_df(path) do
      collect_df(port, [], System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp open_df(path) do
    df_bin = Application.get_env(:cinder, :disk_df_bin, "df")

    case System.find_executable(df_bin) do
      nil ->
        {:error, :df_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              args: Enum.map(["-kP", path], &String.to_charlist/1)
            ]
          )

        {:ok, port}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp collect_df(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_df(port, [data | output], deadline)

      {^port, {:exit_status, 0}} ->
        output |> Enum.reverse() |> IO.iodata_to_binary() |> parse_df()

      {^port, {:exit_status, status}} ->
        {:error, {:df_exit, status}}
    after
      remaining ->
        terminate_port(port)
        {:error, :timeout}
    end
  end

  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ =
          System.cmd(
            "/bin/sh",
            ["-c", ~S|kill -KILL "$1"|, "kill", Integer.to_string(pid)],
            stderr_to_stdout: true
          )

      nil ->
        :ok
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      100 ->
        if Port.info(port), do: Port.close(port)
    end
  catch
    _kind, _reason -> :ok
  end

  defp parse_df(output) do
    with data when is_binary(data) <- output |> String.split("\n", trim: true) |> List.last(),
         [_filesystem, total_kib, _used_kib, avail_kib | _rest] <- String.split(data),
         {total_kib, ""} <- Integer.parse(total_kib),
         {avail_kib, ""} <- Integer.parse(avail_kib),
         true <- total_kib > 0 do
      {:ok, %{free_bytes: avail_kib * 1024, total_bytes: total_kib * 1024}}
    else
      _malformed -> {:error, :unreadable}
    end
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
  Disk stats for every monitored root (`monitored_roots/0`: library roots + the database volume),
  read through the `:disk_prober` seam so tests and alternate probers share the aggregate path.
  One row per root: `%{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}`.
  """
  @spec check_all() :: [
          %{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}
        ]
  def check_all do
    for {kind, path} <- monitored_roots() do
      %{kind: kind, path: path, status: prober().stats(path)}
    end
  end
end
