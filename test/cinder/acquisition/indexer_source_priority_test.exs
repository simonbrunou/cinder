defmodule Cinder.Acquisition.IndexerSourcePriorityTest do
  # The interactive mark of `Cinder.Acquisition.IndexerSource.interactive/1` (#1655), which a
  # manual search sets so the built-in source queues its requests ahead of background ones, and
  # the movie poller's search, which never sets it.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Acquisition.{IndexerMock, IndexerSource}
  alias Cinder.Download.Poller

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  describe "interactive/1" do
    test "marks the calling process while fun runs, and answers fun's value" do
      assert IndexerSource.priority() == :background
      assert IndexerSource.interactive(fn -> IndexerSource.priority() end) == :interactive
      assert IndexerSource.priority() == :background
    end

    test "a raise in fun still clears the mark" do
      assert_raise RuntimeError, fn -> IndexerSource.interactive(fn -> raise "boom" end) end
      assert IndexerSource.priority() == :background
    end

    test "a nested call leaves the outer mark in place" do
      IndexerSource.interactive(fn ->
        IndexerSource.interactive(fn -> :ok end)
        assert IndexerSource.priority() == :interactive
      end)
    end

    test "another process started inside fun is not marked" do
      other =
        IndexerSource.interactive(fn ->
          Task.async(fn -> IndexerSource.priority() end) |> Task.await()
        end)

      assert other == :background
    end
  end

  test "the movie poller's search is background" do
    on_exit(fn -> :persistent_term.erase({Poller, :last_run}) end)
    movie_fixture(%{title: "Plain", year: 2020, imdb_id: "tt0133093"})
    test_pid = self()

    stub(IndexerMock, :search, fn "tt0133093" ->
      send(test_pid, {:priority, IndexerSource.priority()})
      {:ok, []}
    end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    assert :ok = Poller.poll()

    assert_received {:priority, :background}
  end
end
