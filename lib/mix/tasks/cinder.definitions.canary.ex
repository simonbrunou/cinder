defmodule Mix.Tasks.Cinder.Definitions.Canary do
  @shortdoc "Load-check every upstream indexer definition the engine reads, and count the answers"
  @moduledoc """
  Fetches the upstream indexer definitions and runs the load check
  (`Cinder.Indexers.Definitions.LoadCheck.check/2`) on every file in the folders the engine reads
  (`Cinder.Indexers.Definitions.engine_files/1`), then prints one line per "not supported"
  feature with the number of files that use it, one line per load-failure reason with its count,
  and a total (#1667, part of #1610).

      mix cinder.definitions.canary [commit]

  With a commit, it downloads that commit through the configured source's download callback and
  reads it with `Cinder.Indexers.Definitions.Archive.read/2`. Without one, it reads `master`'s
  current commit through `Cinder.Indexers.Definitions.Source.fetch/1`.

  It writes no database row and never applies the set. It is opt-in on the dev host: nothing
  schedules it and CI never runs it. It starts Req, the YAML reader and the request supervisor,
  not the Cinder application.

  A release has no Mix: this task runs only from a checkout.
  """
  use Mix.Task

  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Archive, Source}

  @impl true
  def run(args) do
    commit =
      case args do
        [] -> nil
        [commit] -> commit
        _more -> Mix.raise("mix cinder.definitions.canary takes at most one argument, a commit")
      end

    start()

    case fetch(commit) do
      {:ok, set} -> set |> report() |> Enum.each(fn line -> Mix.shell().info(line) end)
      {:error, reason} -> Mix.raise("Fetching the definitions failed: #{inspect(reason)}")
    end
  end

  defp start do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started([:req, :yaml_elixir])

    if Process.whereis(Cinder.HTTPPolicy.TaskSupervisor) == nil do
      {:ok, _pid} = Task.Supervisor.start_link(name: Cinder.HTTPPolicy.TaskSupervisor)
    end

    :ok
  end

  defp fetch(nil) do
    case Source.fetch(nil) do
      {:ok, _commit, set} -> {:ok, set}
      {:error, _reason} = error -> error
    end
  end

  defp fetch(commit) do
    source = Application.fetch_env!(:cinder, :indexer_definitions_source)

    with {:ok, zip} <- source.download(commit) do
      Archive.read(zip, commit)
    end
  end

  @doc false
  # The lines the task prints for `set`; public for its test, which passes
  # `Definitions.check_copies/2`'s `:check` seam in `opts`.
  @spec report(Cinder.Indexers.Definitions.Set.t(), keyword()) :: [String.t()]
  def report(set, opts \\ []) do
    files = Definitions.engine_files(set)

    copies =
      Enum.map(files, fn {_folder, file} -> %{blob_sha: file.blob_sha, bytes: file.bytes} end)

    answers = Definitions.check_copies(copies, opts)

    unsupported =
      for {_sha, {:ok, %{unsupported: codes}}} <- answers, code <- codes, do: code

    failures = for {_sha, {:error, reason}} <- answers, do: reason_tag(reason)
    loads = Enum.count(answers, &match?({_sha, {:ok, %{unsupported: []}}}, &1))
    not_supported = Enum.count(answers, &match?({_sha, {:ok, %{unsupported: [_ | _]}}}, &1))

    folders = files |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    ["Definitions at #{set.commit}: #{length(files)} files in #{folder_list(folders)}"] ++
      count_lines("not supported", unsupported) ++
      count_lines("fails to load", failures) ++
      [
        "total: #{length(files)} files, #{loads} load, #{not_supported} not supported, " <>
          "#{length(failures)} fail to load, #{length(files) - length(answers)} not checked"
      ]
  end

  defp folder_list([]), do: "no folder"
  defp folder_list(folders), do: Enum.map_join(folders, ", ", &"v#{&1}")

  # A reason that carries a path or a line counts under its tag.
  defp reason_tag({tag, _detail}), do: tag
  defp reason_tag(tag), do: tag

  defp count_lines(label, values) do
    values
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, inspect(value)} end)
    |> Enum.map(fn {value, count} -> "#{label}: #{inspect(value)}: #{count}" end)
  end
end
