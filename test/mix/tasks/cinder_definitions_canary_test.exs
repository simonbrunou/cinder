defmodule Mix.Tasks.Cinder.Definitions.CanaryTest do
  # Swaps the Mix shell, which every process reads; the checks start real parser workers.
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Indexers.Definitions.{Archive, Loader, SourceMock}
  alias Cinder.Test.DefinitionsZip
  alias Mix.Tasks.Cinder.Definitions.Canary

  setup :verify_on_exit!

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  @commit String.duplicate("c", 40)
  @master String.duplicate("d", 40)

  defp yaml(id, rows \\ "tr") do
    Jason.encode!(%{
      "id" => id,
      "name" => "Cinder Test #{id}",
      "description" => "Written for Cinder's tests",
      "language" => "en-US",
      "type" => "public",
      "encoding" => "UTF-8",
      "links" => ["https://tracker.invalid/"],
      "settings" => [],
      "caps" => %{"modes" => %{"search" => ["q"]}},
      "search" => %{
        "rows" => %{"selector" => rows},
        "fields" => %{"title" => %{"selector" => "a"}}
      }
    })
  end

  # v11 holds a copy that loads, one whose selector holds a comment and one that does not parse;
  # v12 holds another copy of a.yml. v10 sits below MIN_VERSION and v13 above the engine.
  defp zip(commit) do
    DefinitionsZip.codeload(commit, [
      {"VERSIONS", "MIN_VERSION=11\nMAX_VERSION=12\n"},
      {"definitions/v10/low.yml", "id: [unclosed"},
      {"definitions/v11/a.yml", yaml("a")},
      {"definitions/v11/b.yml", yaml("b", "tr /* x */")},
      {"definitions/v11/c.yml", "id: [unclosed"},
      {"definitions/v12/a.yml", yaml("a-v12")},
      {"definitions/v13/z.yml", "id: [unclosed"}
    ])
  end

  defp lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | lines()]
    after
      0 -> []
    end
  end

  defp row_counts do
    %{rows: tables} =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")

    for [table] <- tables, into: %{} do
      %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
      {table, count}
    end
  end

  defp expected(commit) do
    [
      "Definitions at #{commit}: 4 files in v11, v12",
      "not supported: {:selector, :comment}: 1",
      "fails to load: :yaml_syntax: 1",
      "total: 4 files, 2 load, 1 not supported, 1 fail to load, 0 not checked"
    ]
  end

  test "with a commit, downloads it and prints the per-feature counts, writing no row" do
    expect(SourceMock, :download, fn @commit -> {:ok, zip(@commit)} end)
    before = row_counts()
    assert Map.has_key?(before, "indexer_definition_set")

    Canary.run([@commit])

    assert lines() == expected(@commit)
    assert row_counts() == before
  end

  test "without a commit, reads master's current commit through the source" do
    expect(SourceMock, :master_commit, fn -> {:ok, @master} end)
    expect(SourceMock, :download, fn @master -> {:ok, zip(@master)} end)
    before = row_counts()

    Canary.run([])

    assert lines() == expected(@master)
    assert row_counts() == before
  end

  test "a fetch error stops the task with its reason" do
    expect(SourceMock, :download, fn @commit -> {:error, {:http_status, 404}} end)

    assert_raise Mix.Error, "Fetching the definitions failed: {:http_status, 404}", fn ->
      Canary.run([@commit])
    end

    expect(SourceMock, :master_commit, fn -> {:error, :timeout} end)

    assert_raise Mix.Error, "Fetching the definitions failed: :timeout", fn ->
      Canary.run([])
    end
  end

  test "counts a check that raised as not checked" do
    {:ok, set} = Archive.read(zip(@commit), @commit)
    broken = yaml("b", "tr /* x */")

    check = fn
      ^broken -> raise "boom"
      bytes -> Loader.load(bytes)
    end

    {lines, log} = ExUnit.CaptureLog.with_log(fn -> Canary.report(set, check: check) end)

    assert List.last(lines) ==
             "total: 4 files, 2 load, 0 not supported, 1 fail to load, 1 not checked"

    assert log =~ "indexer definition load check raised"
  end

  test "takes at most one argument" do
    assert_raise Mix.Error, ~r/at most one argument/, fn -> Canary.run([@commit, @commit]) end
  end
end
