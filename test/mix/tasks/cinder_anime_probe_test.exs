defmodule Mix.Tasks.Cinder.Anime.ProbeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Cinder.ConfigCase
  alias Mix.Tasks.Cinder.Anime.Probe

  @tmdb_stub __MODULE__.TMDBStub
  @prowlarr_stub __MODULE__.ProwlarrStub
  @worker_modules [
    Cinder.Download.Poller,
    Cinder.Download.TvPoller,
    Cinder.Catalog.Refresher,
    Cinder.Subtitles.Sweeper
  ]

  test "starts the application without background workers and restores configuration" do
    script = """
    Application.put_env(:cinder, :start_poller, true)

    try do
      Mix.Tasks.Cinder.Anime.Probe.run(["--corpus", "/missing-anime-probe-corpus"])
    rescue
      File.Error -> :ok
    end

    child_ids =
      Cinder.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    workers = #{inspect(@worker_modules)}
    result = {Enum.filter(workers, &(&1 in child_ids)), Application.fetch_env!(:cinder, :start_poller)}

    IO.puts("PROBE_STARTUP_RESULT=" <> Base.encode64(:erlang.term_to_binary(result)))
    System.halt(0)
    """

    {output, 0} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    [encoded] = Regex.run(~r/PROBE_STARTUP_RESULT=(\S+)/, output, capture: :all_but_first)
    assert {[], true} = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    assert Application.fetch_env!(:cinder, :start_poller) == false
  end

  @tag :tmp_dir
  test "writes sanitized JSON and Markdown artifacts", %{tmp_dir: tmp_dir} do
    paths = paths(tmp_dir)
    configure_providers()
    stub_success()

    output = capture_io(fn -> run_probe(paths) end)

    assert %{"decision" => "tmdb_sufficient", "a0_status" => "pass"} =
             paths.json |> File.read!() |> Jason.decode!()

    assert File.read!(paths.markdown) =~ "Decision: `tmdb_sufficient`"
    assert File.read!(paths.markdown) =~ "A0 status: `pass`"

    artifacts = output <> File.read!(paths.json) <> File.read!(paths.markdown)
    refute artifacts =~ "downloadUrl"
    refute artifacts =~ "download-secret"
    refute artifacts =~ "prowlarr-key"
    refute_temporary_files(paths)
  end

  @tag :tmp_dir
  test "missing TMDB token writes no artifacts", %{tmp_dir: tmp_dir} do
    paths = paths(tmp_dir)
    configure_providers(token: nil)

    assert_raise Mix.Error, ~r/TMDB.HTTP token is not configured/, fn ->
      capture_io(fn -> run_probe(paths) end)
    end

    refute_artifacts(paths)
  end

  @tag :tmp_dir
  test "missing Prowlarr API key writes no artifacts", %{tmp_dir: tmp_dir} do
    paths = paths(tmp_dir)
    configure_providers(api_key: "")

    assert_raise Mix.Error, ~r/Indexer.Prowlarr api_key is not configured/, fn ->
      capture_io(fn -> run_probe(paths) end)
    end

    refute_artifacts(paths)
  end

  @tag :tmp_dir
  test "invalid options write no artifacts", %{tmp_dir: tmp_dir} do
    paths = paths(tmp_dir)

    assert_raise Mix.Error, "invalid anime probe options", fn ->
      capture_io(fn -> run_probe(paths, ["--unknown"]) end)
    end

    refute_artifacts(paths)
  end

  @tag :tmp_dir
  test "provider errors are sanitized and write no artifacts", %{tmp_dir: tmp_dir} do
    paths = paths(tmp_dir)
    configure_providers()

    Req.Test.stub(@tmdb_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"token" => "provider-secret"})
    end)

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn -> run_probe(paths) end)
      end

    assert error.message =~ "anime probe failed"
    refute error.message =~ "provider-secret"
    refute error.message =~ "tmdb-token"
    refute_artifacts(paths)
  end

  defp paths(tmp_dir) do
    corpus = Path.join(tmp_dir, "input/corpus.json")
    json = Path.join(tmp_dir, "output/data/report.json")
    markdown = Path.join(tmp_dir, "output/report.md")

    fixture = "test/support/fixtures/anime/corpus-v1.json" |> File.read!() |> Jason.decode!()
    title = Enum.find(fixture["titles"], &(&1["slug"] == "your-name"))
    File.mkdir_p!(Path.dirname(corpus))
    File.write!(corpus, Jason.encode!(%{fixture | "titles" => [title]}))

    %{corpus: corpus, json: json, markdown: markdown}
  end

  defp configure_providers(overrides \\ []) do
    ConfigCase.put_config(
      Cinder.Catalog.TMDB.HTTP,
      token: Keyword.get(overrides, :token, "tmdb-token"),
      base_url: "https://tmdb.test",
      req_options: [plug: {Req.Test, @tmdb_stub}, retry: false]
    )

    ConfigCase.put_config(
      Cinder.Acquisition.Indexer.Prowlarr,
      api_key: Keyword.get(overrides, :api_key, "prowlarr-key"),
      base_url: "https://prowlarr.test",
      req_options: [plug: {Req.Test, @prowlarr_stub}, retry: false]
    )
  end

  defp stub_success do
    Req.Test.stub(@tmdb_stub, fn conn ->
      case conn.request_path do
        "/3/search/movie" ->
          Req.Test.json(conn, %{
            "results" => [%{"id" => 372_058, "title" => "Your Name."}]
          })

        "/3/movie/372058/alternative_titles" ->
          Req.Test.json(conn, %{"titles" => []})

        "/3/movie/372058" ->
          Req.Test.json(conn, %{"id" => 372_058, "title" => "Your Name."})
      end
    end)

    Req.Test.stub(@prowlarr_stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["prowlarr-key"]

      Req.Test.json(conn, [
        %{
          "title" => "[Group] Your Name.",
          "size" => 1_000_000,
          "protocol" => "torrent",
          "categories" => [%{"id" => 5070, "name" => "TV/Anime"}],
          "publishDate" => "2026-07-01T12:00:00Z",
          "indexer" => "private-indexer-name",
          "downloadUrl" => "https://prowlarr.test/download-secret"
        }
      ])
    end)
  end

  defp run_probe(paths, extra_args \\ []) do
    Mix.Task.reenable("cinder.anime.probe")

    Probe.run(
      [
        "--corpus",
        paths.corpus,
        "--json",
        paths.json,
        "--markdown",
        paths.markdown
      ] ++ extra_args
    )
  end

  defp refute_artifacts(paths) do
    refute File.exists?(paths.json)
    refute File.exists?(paths.markdown)
    refute_temporary_files(paths)
  end

  defp refute_temporary_files(paths) do
    assert Path.wildcard(paths.json <> ".tmp-*") == []
    assert Path.wildcard(paths.markdown <> ".tmp-*") == []
  end
end
