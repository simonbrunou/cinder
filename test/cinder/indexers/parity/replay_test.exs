defmodule Cinder.Indexers.Parity.ReplayTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Indexers.Parity.Replay

  defp call(callback, args, outcome), do: %{callback: callback, args: args, outcome: outcome}

  test "implements every IndexerSource callback" do
    callbacks = IndexerSource.behaviour_info(:callbacks)
    assert callbacks != []
    # `function_exported?/3` answers false for a module not loaded yet.
    Code.ensure_loaded!(Replay)

    for {name, arity} <- callbacks do
      assert {name, arity, function_exported?(Replay, name, arity)} == {name, arity, true}
    end
  end

  test "answers each call with the first unanswered recorded call of the same callback and arguments, in order" do
    calls = [
      call(:search_tv, [1, "Show", 1], {:ok, [%{title: "a"}]}),
      call(:search_tv, [1, "Show", 2], {:ok, [%{title: "b"}]}),
      call(:search_tv, [1, "Show", 1], {:error, :timeout}),
      call(:search_movie_query, ["Dune 2021", [categories: [5070]]], {:ok, []})
    ]

    {answers, outcome} =
      Replay.run(calls, fn ->
        [
          Replay.search_tv(1, "Show", 2),
          Replay.search_tv(1, "Show", 1),
          Replay.search_tv(1, "Show", 1),
          Replay.search_movie_query("Dune 2021", categories: [5070])
        ]
      end)

    assert answers == [
             {:ok, [%{title: "b"}]},
             {:ok, [%{title: "a"}]},
             {:error, :timeout},
             {:ok, []}
           ]

    assert outcome == %{unanswered: [], not_recorded: []}
  end

  test "search_movie/3 matches on its id, its text and its opts" do
    calls = [
      call(:search_movie, ["tt1", "Dune 2021", [categories: [2000]]], {:ok, [%{title: "a"}]})
    ]

    {answers, outcome} =
      Replay.run(calls, fn ->
        [
          Replay.search_movie("tt1", "Dune 2021", []),
          Replay.search_movie("tt1", "Dune", categories: [2000]),
          Replay.search_movie("tt1", "Dune 2021", categories: [2000])
        ]
      end)

    assert answers == [{:error, :not_recorded}, {:error, :not_recorded}, {:ok, [%{title: "a"}]}]
    assert outcome.unanswered == []
  end

  test "a call with no recorded match is {:error, :not_recorded} and reported; unasked calls are reported" do
    calls = [call(:search, ["tt1"], {:ok, []}), call(:search_ebook, [nil, "T", []], {:ok, []})]

    {answers, outcome} =
      Replay.run(calls, fn ->
        [Replay.search("tt1"), Replay.search("tt1"), Replay.search_movie_query("x", [])]
      end)

    assert answers == [{:ok, []}, {:error, :not_recorded}, {:error, :not_recorded}]

    assert outcome == %{
             unanswered: [call(:search_ebook, [nil, "T", []], {:ok, []})],
             not_recorded: [{:search, ["tt1"]}, {:search_movie_query, ["x", []]}]
           }
  end

  test "outside run/2 a callback raises, and run/2 leaves no state behind, also when its function raises" do
    assert_raise ArgumentError, fn -> Replay.search("tt1") end

    assert_raise RuntimeError, fn -> Replay.run([], fn -> raise "boom" end) end
    assert_raise ArgumentError, fn -> Replay.search("tt1") end

    # A nested run restores the outer state.
    {{inner, outer}, _outcome} =
      Replay.run([call(:search, ["tt1"], {:ok, [:outer]})], fn ->
        {inner, _} =
          Replay.run([call(:search, ["tt1"], {:ok, [:inner]})], fn -> Replay.search("tt1") end)

        {inner, Replay.search("tt1")}
      end)

    assert {inner, outer} == {{:ok, [:inner]}, {:ok, [:outer]}}
  end

  test "health and fetch_download send nothing and answer :not_supported" do
    assert Replay.health() == {:error, :not_supported}
    assert Replay.fetch_download("https://x.example/a.nzb", nil, []) == {:error, :not_supported}
  end
end
