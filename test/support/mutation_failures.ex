defmodule Cinder.MutationFailures do
  @moduledoc """
  An ExUnit formatter that appends each failure block to the file the `CINDER_MUTATION_FAILURES`
  env var names, for `scripts/mutation-check` (#1532).

  The script reads that file for the failed tests it lists under a killed mutant. It read the run's
  stdout before, where a line that a passing test prints in the shape of a failure header
  (`  1) test name (Module)`) looks like one ExUnit printed. The file holds only the blocks
  ExUnit formats for a failure:

    * a failed test's block is the text of `ExUnit.Formatter.format_test_failure/5`;
    * a failed `setup_all`'s block is the text of `ExUnit.Formatter.format_test_all_failure/5`.

  The formatter adds no colour, so a block holds escape codes only when a test's own message
  does, and it formats at a width of 80 columns. The blocks are numbered 1, 2, 3 in the order
  ExUnit sends the failures. `ExUnit.CLIFormatter` numbers a failed test the same way, but adds
  to its count for a failed module (its `setup_all`, or an `on_exit` it registered there) one per
  test of that module that passed, where the file adds one. From the first failed module on, its
  numbers can then differ from the file's.
  The output a test captured or logged stays out.

  `test/test_helper.exs` lists it after `ExUnit.CLIFormatter`. When the env var is unset or
  empty, it writes nothing. A run whose `--formatter` switch replaces that list writes nothing
  either. A process a test starts inherits the env var, so a test that runs another `mix test`
  with this helper adds that run's failures to the file.

  When a write fails, such as to a path that names a folder, it prints one line on stderr and
  writes no further block, so the file keeps only the blocks written before. It does not raise:
  ExUnit stops each formatter at the end of the run, and a formatter that crashed makes that stop
  raise after the `Result:` line.
  """

  use GenServer

  @env_var "CINDER_MUTATION_FAILURES"
  @width 80

  @doc "The env var that names the file."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @impl true
  def init(_opts) do
    path =
      case System.get_env(@env_var) do
        "" -> nil
        path -> path
      end

    {:ok, %{path: path, counter: 0}}
  end

  @impl true
  def handle_cast(_event, %{path: nil} = state), do: {:noreply, state}

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    counter = state.counter + 1
    text = ExUnit.Formatter.format_test_failure(test, failures, counter, @width, &plain/2)
    {:noreply, %{state | counter: counter, path: append(state.path, text)}}
  end

  def handle_cast(
        {:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = module},
        state
      ) do
    counter = state.counter + 1
    text = ExUnit.Formatter.format_test_all_failure(module, failures, counter, @width, &plain/2)
    {:noreply, %{state | counter: counter, path: append(state.path, text)}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # The path to write the next block to: nil once a write failed.
  defp append(path, text) do
    case File.write(path, text, [:append]) do
      :ok ->
        path

      {:error, reason} ->
        IO.puts(
          :stderr,
          "#{inspect(__MODULE__)}: cannot write #{path}: #{:file.format_error(reason)}"
        )

        nil
    end
  end

  # A formatter callback that adds no colour: it returns each value as given, so
  # `:diff_enabled?` gets back the `false` that `ExUnit.Formatter` passes with it.
  defp plain(_key, value), do: value
end
