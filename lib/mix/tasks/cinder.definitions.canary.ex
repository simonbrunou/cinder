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

  Then the fixed-query half (#1671, #1624 point 5): for each definition of a named list of public
  definitions that need no login, `nyaasi` then `torrent9`, it sends one fixed query, the first
  request of its plan, to the definition's first link, through the Cardigann adapter's own request
  and row code (`Cinder.Acquisition.Indexer.Cardigann.Fetch` and `Rows`, with no spacing lease
  and no status write), and prints one line: the row count when the page gave at least one row
  and every row had every required field (a title and a link); else `FAILED` with `0 rows`, or
  with the row count, the number of rows dropped and how many missed each field, or with the
  request's failure. A definition the set lacks, or that reads not supported or fails to load,
  gets its line with its feature or reason and no request. No line holds a URL or a row's link. The
  task fails after printing when a fixed query failed.

  It writes no database row and never applies the set. It is opt-in on the dev host: nothing
  schedules it and CI never runs it. It starts Req, the YAML reader and the request supervisor,
  not the Cinder application.

  A release has no Mix: this task runs only from a checkout.
  """
  use Mix.Task

  alias Cinder.Acquisition.Indexer.Cardigann.{Fetch, Query, Rows}
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Archive, CredentialHosts, Source}

  # The fixed query of each public definition the second half asks, in order.
  @fixed_queries [
    {"nyaasi", {:search_tv_query, "frieren", [categories: [5070]]}},
    {"torrent9", {:search_movie_query, "dune", []}}
  ]
  @deadline_ms 90_000

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
      {:ok, set} ->
        lines = report(set)
        Enum.each(lines, fn line -> Mix.shell().info(line) end)

        if Enum.any?(lines, &String.contains?(&1, ": FAILED")),
          do: Mix.raise("A fixed query failed")

      {:error, reason} ->
        Mix.raise("Fetching the definitions failed: #{inspect(reason)}")
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
      ] ++ fixed_query_lines(files, Map.new(answers))
  end

  # --- the fixed-query half ---

  defp fixed_query_lines(files, answers) do
    for {name, query} <- @fixed_queries do
      "fixed query: #{name}: " <> fixed_query(newest(files, name <> ".yml"), answers, query)
    end
  end

  # The copy of `file_name` in the highest folder the engine reads, as the mirror keeps it.
  defp newest(files, file_name) do
    files
    |> Enum.filter(fn {_folder, file} -> file.name == file_name end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
  end

  defp fixed_query(nil, _answers, _query), do: "not in the set"

  defp fixed_query({_folder, file}, answers, query) do
    case Map.get(answers, file.blob_sha) do
      {:ok, %{unsupported: []} = definition} -> ask(definition, query)
      {:ok, %{unsupported: [code | _]}} -> "not supported: #{inspect(code)}"
      {:error, reason} -> "fails to load: #{inspect(reason_tag(reason))}"
      nil -> "not checked"
    end
  end

  defp ask(definition, query) do
    now = DateTime.utc_now()

    base_url = CredentialHosts.effective_base_url(definition, nil)
    config = %{base_url: HTTPPolicy.without_fragment(base_url), values: %{}}

    case Query.plan(definition, config, query, now) do
      {:not_asked, :caps} -> "not asked: caps"
      {:ok, [{:error, reason} | _]} -> "FAILED: #{inspect(reason)}"
      {:ok, [{:ok, planned} | _]} -> first_page(definition, planned, now)
    end
  end

  defp first_page(definition, %{urls: [url | _]} = planned, now) do
    deadline_at = System.monotonic_time(:millisecond) + @deadline_ms

    request = %{
      context: %{deadline_at: deadline_at},
      follow_redirects?: definition.followredirect == true,
      secrets: [],
      secret_referenced?: false,
      link_secret_referenced?: false,
      credential_hosts: CredentialHosts.hosts(definition, %{stored_url: nil, settings: %{}}),
      now: now
    }

    with {:ok, body, uri} <- Fetch.get(url, request),
         {:ok, page} <-
           Rows.read(
             body,
             definition,
             planned.variables,
             uri,
             planned.andmatch,
             deadline_at,
             request
           ) do
      rows_line(length(page.rows), page.missing)
    else
      {:error, reason} -> "FAILED: #{inspect(NewznabAnswer.reason(reason))}"
    end
  end

  defp first_page(_definition, %{urls: []}, _now), do: "FAILED: no search path"

  defp rows_line(0, []), do: "FAILED: 0 rows"
  defp rows_line(count, []), do: "#{count} rows, every required field"

  defp rows_line(count, missing) do
    missed =
      missing |> Enum.frequencies() |> Enum.map_join(", ", fn {f, n} -> "#{n} miss #{f}" end)

    "FAILED: #{count} rows, #{length(missing)} dropped: #{missed}"
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
