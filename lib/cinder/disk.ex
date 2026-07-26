defmodule Cinder.Disk do
  @moduledoc """
  Free/total disk-space gauge for a filesystem path. Backs the periodic `[:cinder, :disk]`
  telemetry measurement (`CinderWeb.Telemetry`) and the `/dashboard` disk cards.

  Shells out to `df -kP <path>` rather than adding a library dependency for something this
  small: `-P` (POSIX output format) guarantees one line per filesystem with no line-wrapping
  on a long device name, and `-k` fixes the block size to 1024 bytes, so the same parsing
  works on both the Linux container and macOS dev.
  """

  @type stats :: %{free_bytes: non_neg_integer(), total_bytes: non_neg_integer()}

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
