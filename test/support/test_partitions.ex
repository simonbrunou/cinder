defmodule Cinder.TestPartitions do
  @moduledoc """
  Runs a bare `mix test` as parallel partitions, each in its own OS process (#1473).

  The `test` alias in `mix.exs` calls `run/4` after its compile, format and Credo gates, so the
  gates run once. `plan/2` picks one process, through the alias's own ExUnit step, when
  `CINDER_TEST_PARTITIONS` is `1`, when an argument is a path, or when an argument is a switch
  that does not parse against `@pass_through`. Otherwise it picks `CINDER_TEST_PARTITIONS`
  partitions, 4 when the variable is unset.

  Each partition runs `mix test.unchecked --partitions <count> <args>`, all of them at once, with:

    * `MIX_TEST_PARTITION` set to its number. Mix deals the sorted test files round-robin by that
      number, so each file runs in one partition, and `config/test.exs` names the partition's
      own database file after it.
    * `MIX_BUILD_PATH` set to `test-partitions/<number>` beside the build folder (`_build/test`,
      or the folder `MIX_BUILD_PATH` names), a `cp -a --reflink=auto` copy of it made after the
      gates compiled it. `CinderWeb.TranslationsCompleteTest` runs `mix gettext.extract`, which
      recompiles the project into its build folder: with one shared folder, the other partitions
      lost their modules mid-run.

  A partition's output goes to `test-partitions/<number>.log`. `run/4` prints a passed
  partition's log as it ends and a failed one's after every partition ended, then one summary
  line per partition, and raises `Mix.Error` when any partition exited non-zero. The exit status
  alone decides: a run that aborts on a test-file warning exits non-zero after a `Result:` line
  that counts no failure (docs/agents/ci.md "Test-file warning").

  Each partition writes ExUnit's failures manifest into its own build folder. `merge_failures!/2`
  folds them back into the build folder's own, so `mix test.unchecked --failed` after a
  partitioned run reads the manifest one process would have left.
  """

  alias Cinder.TestPartitions.Partition

  @default_count 4

  # The switches each partition takes as given, with their types in Mix.Tasks.Test's switch table
  # (Elixir 1.20.5). Every other switch does not parse here and runs one process, among them
  # --failed and --stale (their manifest is per build folder), --cover and --export-coverage (one
  # report per partition), --max-failures (counted per partition), --only and --name-pattern (Mix
  # fails a run they leave with no test, and most partitions hold none of the tests they pick),
  # --breakpoints and --listen-on-stdin (they read the terminal), --formatter (a formatter that
  # writes a file would write it from every partition), --partitions and --exit-status (they
  # change what this module reads), --force (every copy would recompile at once, after the gates
  # compiled), and --repeat-until-failure (a partition that fails stops while the others repeat
  # on). The rest change what a child does before ExUnit (--no-compile, --no-start,
  # --no-deps-check and the other checks, --preload-modules, --max-requires, --profile-require)
  # and were not tried across partitions, so they keep today's one process, as does a switch a
  # later Mix adds.
  @pass_through [
    all_warnings: :boolean,
    color: :boolean,
    dry_run: :boolean,
    exclude: :keep,
    include: :keep,
    max_cases: :integer,
    raise: :boolean,
    seed: :integer,
    slowest: :integer,
    slowest_modules: :integer,
    timeout: :integer,
    trace: :boolean,
    warnings_as_errors: :boolean
  ]

  @manifest_name ".mix_test_failures"
  @manifest_vsn 1

  @doc """
  `:one_process`, or `{:partitions, count}` for `args` and the value of `CINDER_TEST_PARTITIONS`
  (`nil` when unset). Raises `Mix.Error` when that value is not a positive integer, paths or not.
  """
  @spec plan([String.t()], String.t() | nil) :: :one_process | {:partitions, pos_integer()}
  def plan(args, count) do
    case count!(count) do
      1 -> :one_process
      count -> if partitionable?(args), do: {:partitions, count}, else: :one_process
    end
  end

  @doc """
  Runs the suite as `plan/2` says. One process calls `one_process` with `args` and returns what it
  returns. Partitions return `:ok` or raise `Mix.Error`.

  Options, for the tests: `:build`, the build folder to copy (`Mix.Project.build_path/0`), and
  `:start`, a function of the partition, the count and `args` that runs the partition and returns
  its exit status (`start/4` with the `mix` on `PATH`).
  """
  @spec run([String.t()], String.t() | nil, ([String.t()] -> result), keyword()) :: result | :ok
        when result: term()
  def run(args, count, one_process, opts \\ []) do
    case plan(args, count) do
      :one_process -> one_process.(args)
      {:partitions, count} -> run_partitions(args, count, opts)
    end
  end

  @doc """
  Runs `mix test.unchecked --partitions <count> <args>` with `mix` as `partition`, its output and
  stderr in `partition.log`, and returns its exit status.
  """
  @spec start(Partition.t(), pos_integer(), [String.t()], Path.t()) :: non_neg_integer()
  def start(partition, count, args, mix) do
    env = [
      {"MIX_ENV", "test"},
      {"MIX_TEST_PARTITION", Integer.to_string(partition.n)},
      {"MIX_BUILD_PATH", partition.build}
    ]

    {_, status} =
      System.cmd(mix, ["test.unchecked", "--partitions", Integer.to_string(count) | args],
        env: env,
        stderr_to_stdout: true,
        into: File.stream!(partition.log)
      )

    status
  end

  @doc """
  Writes into `base` the failures manifest a single run would have left: `base`'s entries, less
  each test a partition dropped from its copy (it passed or is gone), plus each one a partition
  added (it failed). A partition that marked its whole suite failed (`ExUnit.Filters.fail_all!/1`)
  marks the merged one so. A missing file holds no failure. Raises `Mix.Error` naming any file
  that is not a version 1 manifest.
  """
  @spec merge_failures!(Path.t(), [Path.t()]) :: :ok
  def merge_failures!(base, partitions) do
    # ExUnit reads a whole-suite mark as no failure when a run starts, so each copy started empty.
    before =
      case read_failures!(base) do
        :all -> %{}
        failures -> failures
      end

    copies = Enum.map(partitions, &read_failures!/1)

    merged =
      if :all in copies do
        :all
      else
        dropped = for copy <- copies, id <- Map.keys(before), not Map.has_key?(copy, id), do: id

        added =
          for copy <- copies, {id, file} <- copy, Map.get(before, id) != file, into: %{} do
            {id, file}
          end

        before |> Map.drop(dropped) |> Map.merge(added)
      end

    File.mkdir_p!(Path.dirname(base))
    File.write!(base, :erlang.term_to_binary({@manifest_vsn, merged}))
  end

  defp count!(nil), do: @default_count

  defp count!(value) do
    case Integer.parse(value) do
      {count, ""} when count > 0 ->
        count

      _ ->
        Mix.raise(
          "mix test: CINDER_TEST_PARTITIONS must be a positive integer, got: #{inspect(value)}"
        )
    end
  end

  defp partitionable?(args) do
    match?({_opts, [], []}, OptionParser.parse(args, strict: @pass_through))
  end

  defp run_partitions(args, count, opts) do
    build = Keyword.get_lazy(opts, :build, &Mix.Project.build_path/0)
    start = Keyword.get_lazy(opts, :start, &default_start/0)
    root = Path.join(Path.dirname(build), "test-partitions")
    File.mkdir_p!(root)

    partitions =
      for n <- 1..count do
        %Partition{n: n, build: Path.join(root, "#{n}"), log: Path.join(root, "#{n}.log")}
      end

    for partition <- partitions do
      copy_build!(build, partition.build)
      File.rm_rf!(partition.log)
    end

    ended =
      partitions
      |> Task.async_stream(&%{&1 | status: start.(&1, count, args)},
        max_concurrency: count,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, partition} ->
        if partition.status == 0, do: print_log(partition, count)
        partition
      end)
      |> Enum.sort_by(& &1.n)

    failed = Enum.reject(ended, &(&1.status == 0))
    Enum.each(failed, &print_log(&1, count))
    merge_failures!(manifest(build), Enum.map(partitions, &manifest(&1.build)))

    for partition <- ended do
      Mix.shell().info(
        "mix test: partition #{partition.n} of #{count}: exit #{partition.status}, " <>
          result_line(partition.log)
      )
    end

    case failed do
      [] ->
        Mix.shell().info("mix test: #{count} of #{count} partitions passed")

      failed ->
        Mix.raise(
          "mix test: #{length(failed)} of #{count} partitions failed: " <>
            Enum.map_join(failed, ", ", & &1.n)
        )
    end
  end

  defp default_start do
    mix = System.find_executable("mix") || Mix.raise("mix test: no mix on PATH")
    &start(&1, &2, &3, mix)
  end

  defp copy_build!(build, copy) do
    File.rm_rf!(copy)

    case System.cmd("cp", ["-a", "--reflink=auto", build, copy], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> Mix.raise("mix test: copying #{build} to #{copy} exited #{status}: #{out}")
    end
  end

  # The manifest Mix.Tasks.Test writes under `build`, at the place it has under the project's own.
  defp manifest(build) do
    relative = Path.relative_to(Mix.Project.manifest_path(), Mix.Project.build_path())
    Path.join([build, relative, @manifest_name])
  end

  defp print_log(partition, count) do
    Mix.shell().info(
      "==> mix test: partition #{partition.n} of #{count} exited #{partition.status}"
    )

    IO.write(File.read!(partition.log))
  end

  defp result_line(log) do
    log
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "Result: "))
    # Worded without "Result:", so a search of the log for that word skips a partition with none.
    |> List.last("ExUnit printed no result line")
  end

  defp read_failures!(file) do
    case File.read(file) do
      {:ok, binary} ->
        decode_failures!(file, binary)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Mix.raise("mix test: cannot read #{file}: #{:file.format_error(reason)}")
    end
  end

  defp decode_failures!(file, binary) do
    case safe_binary_to_term(binary) do
      {@manifest_vsn, %{} = failures} -> failures
      {@manifest_vsn, :all} -> :all
      _ -> Mix.raise("mix test: #{file} is not a version 1 ExUnit failures manifest")
    end
  end

  defp safe_binary_to_term(binary) do
    :erlang.binary_to_term(binary)
  rescue
    ArgumentError -> :not_a_term
  end
end
