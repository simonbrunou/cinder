defmodule Cinder.CatalogDiscoverTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog

  setup :verify_on_exit!

  setup do
    # search_discover always hits all four endpoints; default persons/collections empty.
    stub(Cinder.Catalog.TMDBMock, :search_person, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, _ -> {:ok, []} end)
    :ok
  end

  @movie %{tmdb_id: 1, title: "A Movie", year: 2000, poster_path: "/m.jpg"}
  @show %{tmdb_id: 2, title: "A Show", year: 2001, poster_path: "/s.jpg"}

  test "a blank query short-circuits to {:ok, []} with no TMDB call" do
    assert {:ok, []} = Catalog.search_discover("   ")
  end

  test "tags each result :movie/:tv and interleaves them" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, "en" -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, "en" -> {:ok, [@show]} end)

    assert {:ok, results} = Catalog.search_discover("x")
    assert Enum.map(results, & &1.type) == [:movie, :tv]
    assert Enum.map(results, & &1.tmdb_id) == [1, 2]
  end

  @tag :capture_log
  test "one endpoint erroring still yields the other's results" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, "en" -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, "en" -> {:error, :timeout} end)

    assert {:ok, [%{type: :movie, tmdb_id: 1}]} = Catalog.search_discover("x")
  end

  # The four sides run as tasks linked to the caller; the task fun must convert a
  # raise/exit into the side's {:error, _} contract or it takes the LiveView down.
  @tag :capture_log
  test "a side that raises is omitted instead of crashing the caller" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, "en" -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, "en" -> {:ok, [@show]} end)
    stub(Cinder.Catalog.TMDBMock, :search_person, fn _, "en" -> raise "boom" end)

    assert {:ok, results} = Catalog.search_discover("x")
    assert Enum.map(results, & &1.tmdb_id) == [1, 2]
  end

  # A pool-checkout timeout exits (GenServer call timeout) rather than raising.
  @tag :capture_log
  test "a side that exits is omitted instead of crashing the caller" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, "en" -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, "en" -> {:ok, [@show]} end)

    stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, "en" ->
      exit({:timeout, {GenServer, :call, []}})
    end)

    assert {:ok, results} = Catalog.search_discover("x")
    assert Enum.map(results, & &1.tmdb_id) == [1, 2]
  end

  @tag :capture_log
  test "both endpoints erroring yields {:error, :search_failed}" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, "en" -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, "en" -> {:error, :nxdomain} end)
    stub(Cinder.Catalog.TMDBMock, :search_person, fn _, "en" -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, "en" -> {:error, :timeout} end)

    assert {:error, :search_failed} = Catalog.search_discover("x")
  end
end
