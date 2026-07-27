defmodule Cinder.Disk do
  @moduledoc """
  Free/total disk-space gauge for a filesystem path. Backs the periodic `[:cinder, :disk]`
  telemetry measurement (`CinderWeb.Telemetry`) and the `/dashboard` disk cards.

  Shells out to `df -kP <path>` rather than adding a library dependency for something this
  small: `-P` (POSIX output format) guarantees one line per filesystem with no line-wrapping
  on a long device name, and `-k` fixes the block size to 1024 bytes, so the same parsing
  works on both the Linux container and macOS dev.
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
  directory, `{:error, reason}` when `df` fails or its output can't be parsed, and never
  raises. `runner` (default: a real `df` invocation) is an injection seam for tests — an
  arity-0 function returning the `{output, exit_status}` pair `System.cmd/3` would.
  """
  @spec stats(String.t(), (-> {String.t(), non_neg_integer()}) | nil) ::
          {:ok, stats()} | {:error, term()}
  def stats(path, runner \\ nil) when is_binary(path) do
    if File.dir?(path) do
      (runner || default_runner(path)) |> safe_run() |> parse()
    else
      {:error, :enoent}
    end
  end

  defp default_runner(path), do: fn -> System.cmd("df", ["-kP", path], stderr_to_stdout: true) end

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
  Disk stats for every configured library root. One row per root:
  `%{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}`.
  """
  @spec check_all() :: [
          %{kind: atom(), path: String.t(), status: {:ok, stats()} | {:error, term()}}
        ]
  def check_all do
    for {kind, path} <- configured_roots() do
      %{kind: kind, path: path, status: stats(path)}
    end
  end

  defp safe_run(runner) do
    runner.()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp parse({:error, _} = error), do: error
  defp parse({_output, status}) when status != 0, do: {:error, :df_failed}

  defp parse({output, 0}) do
    output
    |> String.split("\n", trim: true)
    |> case do
      [_header, data | _rest] -> parse_line(data)
      _ -> {:error, :unparsable}
    end
  end

  defp parse_line(line) do
    case String.split(line) do
      [_filesystem, total_kb, _used_kb, avail_kb | _rest] ->
        with {total, ""} <- Integer.parse(total_kb),
             {avail, ""} <- Integer.parse(avail_kb) do
          {:ok, %{free_bytes: avail * 1024, total_bytes: total * 1024}}
        else
          _ -> {:error, :unparsable}
        end

      _ ->
        {:error, :unparsable}
    end
  end
end
