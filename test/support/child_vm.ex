defmodule Cinder.Test.ChildVM do
  @moduledoc """
  Starts `elixir -pa <ebin> -e <code>` in a folder through `sh`, for the tests that run a child
  VM on this build's code (`Cinder.MutationFailuresTest`, `Cinder.LostTestsTest`,
  `Cinder.TestPartitionsTest`).

  `open/4` returns the port, for a test that asserts on each line as it comes and acts between
  lines. `sh` prints `exit <status>` once the child ended. `run/4` collects
  the child's output and takes its exit status from the port, so a line the child prints never
  reads as its status. The child's stderr joins its stdout unless the `:stderr` option sends it
  to a file.

  Each message of the port carries at most 4096 bytes of a line. `run/4` joins the pieces of a
  longer line into one; a test that reads the port itself gets them apart.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @timeout_ms 60_000
  @line_bytes 4096

  @doc """
  How long `run/4` waits for the child's next port message by default: a slow boot on a loaded
  host takes seconds.
  """
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc """
  Opens a port on `sh`, which runs `elixir -pa <ebin> -e <code>` in `dir`, then prints
  `exit <status>`. The calling process owns the port.

  Options:

    * `:env` - `{name, value}` exports the variable with that value, `""` included, and
      `{name, nil}` unsets it. `sh` does it, since a port's `env:` unsets a variable whose value
      is empty. Without the option the child inherits the variable as it is.
    * `:stderr` - a file, relative to `dir`, that gets the child's stderr.
    * `:stdin` - a file the child reads its stdin from, such as a FIFO. `sh` opens it before it
      starts the child, so the open of a FIFO waits for a writer.
  """
  @spec open(String.t(), Path.t(), Path.t(), keyword()) :: port()
  def open(code, dir, ebin, opts \\ []), do: start(code, dir, ebin, opts, "marker")

  @doc """
  Runs `code` as `open/4` does, without the `exit <status>` line, and returns the child's output,
  its lines joined with `"\\n"`, and the exit status the port reports. A last line the child
  left without a newline counts as a line. Flunks with the lines so far when the port sends
  nothing for the timeout, so the wait starts again with each message, even one that carries
  only a piece of a line.

  Options, beside those of `open/4`:

    * `:on_line` - a function called with each line and the lines before it, newest first, before
      `run/4` reads the next one. Its last call can get the empty line that `sh`'s closing
      newline adds, which the output leaves out.
    * `:timeout` - the wait for each port message in ms, `timeout_ms/0` by default.
  """
  @spec run(String.t(), Path.t(), Path.t(), keyword()) :: {String.t(), integer()}
  def run(code, dir, ebin, opts \\ []) do
    port = start(code, dir, ebin, opts, "")
    on_line = Keyword.get(opts, :on_line, fn _line, _lines -> :ok end)
    collect(port, on_line, Keyword.get(opts, :timeout, @timeout_ms), "", [])
  end

  defp start(code, dir, ebin, opts, marker) do
    {env_mode, name, value} =
      case Keyword.fetch(opts, :env) do
        {:ok, {name, nil}} -> {"unset", name, ""}
        {:ok, {name, value}} -> {"set", name, value}
        :error -> {"keep", "", ""}
      end

    # `sh` exits with the child's status, which the port reports after the child's output. For
    # `run/4` it prints a newline instead of the `exit` line: the port sends a last piece of a
    # line that no newline ends after the status, where `run/4` has stopped reading.
    script =
      ~s(case "$3" in set\) export "$4=$5";; unset\) unset "$4";; esac; ) <>
        ~s(if [ -n "$6" ]; then exec 2> "$6"; fi; ) <>
        ~s(if [ -n "$7" ]; then exec < "$7"; fi; ) <>
        ~s("$0" -pa "$1" -e "$2"; s=$?; ) <>
        ~s(if [ -n "$8" ]; then echo "exit $s"; else echo; fi; exit $s)

    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      line: @line_bytes,
      cd: dir,
      args: [
        "-c",
        script,
        System.find_executable("elixir"),
        ebin,
        code,
        env_mode,
        name,
        value,
        Keyword.get(opts, :stderr, ""),
        Keyword.get(opts, :stdin, ""),
        marker
      ]
    ])
  end

  defp collect(port, on_line, timeout, piece, lines) do
    receive do
      {^port, {:data, {:noeol, part}}} ->
        collect(port, on_line, timeout, piece <> part, lines)

      {^port, {:data, {:eol, part}}} ->
        line = piece <> part
        on_line.(line, lines)
        collect(port, on_line, timeout, "", [line | lines])

      # The newline `sh` printed last ended the child's last line, or added an empty one.
      {^port, {:exit_status, status}} ->
        lines =
          case lines do
            ["" | lines] -> lines
            lines -> lines
          end

        {Enum.join(Enum.reverse(lines), "\n"), status}
    after
      timeout ->
        flunk(
          "the child sent nothing for #{timeout} ms and did not exit:\n" <>
            Enum.join(Enum.reverse(with_piece(piece, lines)), "\n")
        )
    end
  end

  defp with_piece("", lines), do: lines
  defp with_piece(piece, lines), do: [piece | lines]
end
