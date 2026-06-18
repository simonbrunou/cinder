defmodule Cinder.AcquisitionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Release

  setup :verify_on_exit!

  @gb 1_000_000_000

  # A raw indexer result map with sensible defaults; override per case.
  defp raw(attrs) do
    Map.merge(
      %{title: "Movie.2020.1080p.BluRay.x264-GRP", size: 8 * @gb, download_url: "u", seeders: 10},
      Map.new(attrs)
    )
  end

  test "best_release/2 composes indexer search, parse, and scoring" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [
         raw(title: "Movie.2020.720p.BluRay.x264-GOOD", size: 4 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-BEST", size: 9 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "BEST", resolution: "1080p"}} =
             Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match when nothing survives the rules" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-GRP", size: 50 * @gb)]}
    end)

    assert :no_match = Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match on an empty indexer result" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert :no_match = Acquisition.best_release("tt1375666")
  end

  test "best_release/2 passes an indexer error straight through" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Acquisition.best_release("tt1375666")
  end
end
